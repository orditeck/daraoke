import AudioToolbox
import AVFoundation
import Foundation

/// Fully decoded, immutable planar Float32 audio. Construct this off the main actor.
/// Only short-lived, read-only scheduling views of its storage leave this type.
public final class DecodedAudio: @unchecked Sendable {
    static let maximumPCMBytes: UInt64 = 512 * 1_024 * 1_024

    private let storage: AVAudioPCMBuffer
    var format: AVAudioFormat { storage.format }
    var frameCount: AVAudioFramePosition { AVAudioFramePosition(storage.frameLength) }
    public var duration: TimeInterval { Double(storage.frameLength) / storage.format.sampleRate }

    public init(mp3Data: Data) throws {
        guard !mp3Data.isEmpty else { throw AudioDecodingError.invalidMP3 }
        let source = MemoryAudioFile(data: mp3Data)
        let context = Unmanaged.passUnretained(source).toOpaque()
        var file: AudioFileID?
        let opened = AudioFileOpenWithCallbacks(context, { context, position, count, destination, actual in
            let source = Unmanaged<MemoryAudioFile>.fromOpaque(context).takeUnretainedValue()
            actual.pointee = 0
            guard position >= 0 else { return kAudioFilePositionError }
            guard position < Int64(source.data.count) else { return noErr }
            let offset = Int(position)
            let available = min(Int(count), source.data.count - offset)
            if available > 0 {
                source.data.withUnsafeBytes { bytes in
                    destination.copyMemory(from: bytes.baseAddress!.advanced(by: offset), byteCount: available)
                }
            }
            actual.pointee = UInt32(available)
            return noErr
        }, nil, { context in
            Int64(Unmanaged<MemoryAudioFile>.fromOpaque(context).takeUnretainedValue().data.count)
        }, nil, kAudioFileMP3Type, &file)
        guard opened == noErr, let file else { throw AudioDecodingError.invalidMP3 }
        defer {
            AudioFileClose(file)
            withExtendedLifetime(source) {}
        }

        var extended: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(file, false, &extended) == noErr, let extended else {
            throw AudioDecodingError.invalidMP3
        }
        defer { ExtAudioFileDispose(extended) }

        var original = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard ExtAudioFileGetProperty(extended, kExtAudioFileProperty_FileDataFormat, &size, &original) == noErr,
              original.mFormatID == kAudioFormatMPEGLayer3,
              original.mSampleRate.isFinite, original.mSampleRate > 0,
              (1...2).contains(original.mChannelsPerFrame),
              let format = AVAudioFormat(standardFormatWithSampleRate: original.mSampleRate,
                                         channels: original.mChannelsPerFrame) else {
            throw AudioDecodingError.invalidMP3
        }
        var client = format.streamDescription.pointee
        guard ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr else {
            throw AudioDecodingError.invalidMP3
        }
        var length: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        guard ExtAudioFileGetProperty(extended, kExtAudioFileProperty_FileLengthFrames, &size, &length) == noErr,
              length > 0 else { throw AudioDecodingError.invalidMP3 }
        let capacity = try Self.checkedCapacity(frames: UInt64(length), channels: format.channelCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let channels = buffer.floatChannelData else { throw AudioDecodingError.allocationFailed }
        let list = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
        defer { list.unsafeMutablePointer.deallocate() }
        list.unsafeMutablePointer.pointee.mNumberBuffers = format.channelCount
        var decoded: AVAudioFrameCount = 0
        while decoded < capacity {
            var requested = min(16_384, capacity - decoded)
            for channel in 0..<Int(format.channelCount) {
                list[channel] = AudioBuffer(mNumberChannels: 1,
                                            mDataByteSize: requested * UInt32(MemoryLayout<Float>.size),
                                            mData: channels[channel].advanced(by: Int(decoded)))
            }
            guard ExtAudioFileRead(extended, &requested, list.unsafeMutablePointer) == noErr else {
                throw AudioDecodingError.invalidMP3
            }
            if requested == 0 { break }
            decoded += requested
        }
        // A forged or inconsistent frame count must never silently truncate the song.
        if decoded == capacity {
            var extra: AVAudioFrameCount = 1
            guard ExtAudioFileRead(extended, &extra, list.unsafeMutablePointer) == noErr, extra == 0 else {
                throw AudioDecodingError.invalidMP3
            }
        }
        guard decoded > 0 else { throw AudioDecodingError.invalidMP3 }
        buffer.frameLength = decoded
        storage = buffer
    }

    /// A tiny AudioBufferList is allocated per seek, but the PCM samples are never copied.
    /// The view's deallocator retains this clip even after a subsequent load replaces it.
    func schedulingBuffer(startingAt frame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        guard frame >= 0, frame < frameCount, let channels = storage.floatChannelData else { return nil }
        let remaining = AVAudioFrameCount(frameCount - frame)
        let list = AudioBufferList.allocate(maximumBuffers: Int(format.channelCount))
        defer { list.unsafeMutablePointer.deallocate() }
        list.unsafeMutablePointer.pointee.mNumberBuffers = format.channelCount
        for channel in 0..<Int(format.channelCount) {
            list[channel] = AudioBuffer(mNumberChannels: 1,
                                       mDataByteSize: remaining * UInt32(MemoryLayout<Float>.size),
                                       mData: channels[channel].advanced(by: Int(frame)))
        }
        let view = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) { [self] _ in
            withExtendedLifetime(self) {}
        }
        view?.frameLength = remaining
        return view
    }

    static func checkedCapacity(frames: UInt64, channels: AVAudioChannelCount) throws -> AVAudioFrameCount {
        guard frames > 0, channels > 0 else { throw AudioDecodingError.invalidMP3 }
        let (samples, sampleOverflow) = frames.multipliedReportingOverflow(by: UInt64(channels))
        let (bytes, byteOverflow) = samples.multipliedReportingOverflow(by: UInt64(MemoryLayout<Float>.size))
        guard !sampleOverflow, !byteOverflow, bytes <= maximumPCMBytes, frames <= UInt64(UInt32.max) else {
            throw AudioDecodingError.tooLarge
        }
        return AVAudioFrameCount(frames)
    }

    // Synthetic PCM test seam: values are copied into private storage exactly once, never aliased.
    init(samples: [Float], sampleRate: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw AudioDecodingError.invalidMP3
        }
        let capacity = try Self.checkedCapacity(frames: UInt64(samples.count), channels: 1)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              let destination = buffer.floatChannelData?[0] else { throw AudioDecodingError.allocationFailed }
        samples.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress!, count: source.count)
        }
        buffer.frameLength = capacity
        storage = buffer
    }
}

private final class MemoryAudioFile {
    let data: Data
    init(data: Data) { self.data = data }
}

enum AudioDecodingError: LocalizedError {
    case invalidMP3
    case tooLarge
    case allocationFailed

    var errorDescription: String? {
        switch self {
        case .invalidMP3:
            "The MP3 is empty, damaged, or cannot be decoded. Try another copy of this karaoke ZIP."
        case .tooLarge:
            "The decoded MP3 exceeds the 512 MiB audio limit. Choose a shorter karaoke track."
        case .allocationFailed:
            "There is not enough memory to decode this karaoke track."
        }
    }
}
