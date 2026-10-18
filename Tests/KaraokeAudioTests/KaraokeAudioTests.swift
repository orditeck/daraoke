import AVFoundation
import Foundation
import Testing
@testable import KaraokeAudio

@Suite(.serialized)
@MainActor
struct KaraokeAudioTests {
    private let sampleRate = 44_100.0
    private let quantum: AVAudioFrameCount = 512

    private func sine(seconds: Double = 4, envelope: (Double) -> Double = { _ in 1 }) throws -> DecodedAudio {
        let samples = (0..<Int(seconds * sampleRate)).map { frame in
            let time = Double(frame) / sampleRate
            return Float(0.35 * envelope(time) * sin(2 * .pi * 440 * time))
        }
        return try DecodedAudio(samples: samples, sampleRate: sampleRate)
    }

    private func offline(_ clip: DecodedAudio) throws -> KaraokePlayback {
        let transport = KaraokePlayback()
        try transport.engine.enableManualRenderingMode(.offline, format: clip.format,
                                                        maximumFrameCount: quantum)
        transport.load(clip)
        return transport
    }

    private func render(_ transport: KaraokePlayback, seconds: Double) throws -> [Float] {
        try render(transport, frames: Int((seconds * sampleRate).rounded()))
    }

    private func render(_ transport: KaraokePlayback, frames: Int) throws -> [Float] {
        let output = try #require(AVAudioPCMBuffer(pcmFormat: transport.engine.manualRenderingFormat,
                                                  frameCapacity: quantum))
        var samples: [Float] = []
        samples.reserveCapacity(frames)
        var attemptsWithoutProgress = 0
        while samples.count < frames {
            let count = AVAudioFrameCount(min(Int(quantum), frames - samples.count))
            let status = try transport.engine.renderOffline(count, to: output)
            switch status {
            case .success:
                let channel = try #require(output.floatChannelData?[0])
                #expect(output.frameLength == count)
                guard output.frameLength > 0 else { throw TestFailure.emptyRender }
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
                attemptsWithoutProgress = 0
            case .cannotDoInCurrentContext:
                attemptsWithoutProgress += 1
                guard attemptsWithoutProgress < 100 else { throw TestFailure.renderUnavailable }
            default:
                throw TestFailure.renderUnavailable
            }
        }
        return samples
    }

    private func frequency(_ samples: ArraySlice<Float>) throws -> Double {
        var crossings: [Double] = []
        for index in samples.indices.dropFirst() {
            let previous = Double(samples[index - 1])
            let current = Double(samples[index])
            if previous <= 0, current > 0 {
                crossings.append(Double(index - 1) - previous / (current - previous))
            }
        }
        let first = try #require(crossings.first)
        let last = try #require(crossings.last)
        #expect(crossings.count > 100)
        return Double(crossings.count - 1) * sampleRate / (last - first)
    }

    private func energyCenter(_ samples: [Float], in interval: Range<Double>) throws -> Double {
        let start = Int(interval.lowerBound * sampleRate)
        let end = min(samples.count, Int(interval.upperBound * sampleRate))
        var energy = 0.0
        var moment = 0.0
        for frame in start..<end {
            let squared = Double(samples[frame]) * Double(samples[frame])
            energy += squared
            moment += squared * Double(frame) / sampleRate
        }
        #expect(energy > 1)
        guard energy > 0 else { throw TestFailure.emptyRender }
        return moment / energy
    }

    private func allowCallbacks(_ transport: KaraokePlayback, until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline {
            // Reading the source clock also drains the production offline end/latency transition.
            _ = transport.currentTime
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }

    @Test(arguments: [-2, -1, 0, 1])
    func pitchRatioAndUnchangedTempo(semitones: Int) async throws {
        let clip = try sine()
        let transport = try offline(clip)
        defer { transport.stop() }
        transport.semitones = semitones
        try transport.play()
        let output = try render(transport, seconds: clip.duration + 0.3)
        let measured = try frequency(output[Int(sampleRate)..<Int(sampleRate * 3)])
        let expected = 440 * pow(2, Double(semitones) / 12)
        #expect(abs(measured - expected) < 2)
        let firstAudible = try #require(output.firstIndex { abs($0) > 0.03 })
        let lastAudible = try #require(output.lastIndex { abs($0) > 0.03 })
        let audibleDuration = Double(lastAudible - firstAudible) / sampleRate
        #expect(abs(audibleDuration - clip.duration) < 0.12)
        #expect(transport.duration == clip.duration)
        try await allowCallbacks(transport, until: { !transport.isPlaying })
        #expect(abs(transport.currentTime - clip.duration) < 1 / sampleRate)

        // Two isolated bursts two seconds apart measure tempo in actual rendered audio, not metadata.
        let bursts = try sine { time in
            ((0.5..<1).contains(time) || (2.5..<3).contains(time)) ? 1 : 0
        }
        transport.load(bursts)
        try transport.play()
        let pulsed = try render(transport, seconds: bursts.duration + 0.3)
        let first = try energyCenter(pulsed, in: 0.25..<1.4)
        let second = try energyCenter(pulsed, in: 2.25..<3.4)
        #expect(abs((second - first) - 2) < 0.025)
    }

    @Test
    func liveKeyChangesKeepSourceClockAndDoNotReschedule() throws {
        let clip = try sine(seconds: 6)
        let transport = try offline(clip)
        defer { transport.stop() }
        try transport.play()
        _ = try render(transport, seconds: 1)
        let before = transport.currentTime
        transport.semitones = -2
        #expect(transport.currentTime == before)
        let lower = try render(transport, seconds: 1)
        #expect(abs(try frequency(lower[Int(sampleRate * 0.3)...]) - 440 * pow(2, -2.0 / 12)) < 2)
        #expect(abs((transport.currentTime - before) - 1) < 0.04)
        let middle = transport.currentTime
        transport.semitones = 1
        let higher = try render(transport, seconds: 1)
        #expect(abs(try frequency(higher[Int(sampleRate * 0.3)...]) - 440 * pow(2, 1.0 / 12)) < 2)
        #expect(abs((transport.currentTime - middle) - 1) < 0.04)
        #expect(transport.isPlaying)
        #expect(transport.duration == 6)
    }

    @Test
    func keyBoundsAffectTheRealGraph() throws {
        let clip = try sine()
        let transport = try offline(clip)
        defer { transport.stop() }
        transport.semitones = Int.min
        #expect(transport.semitones == -12)
        try transport.play()
        let low = try render(transport, seconds: 1.5)
        #expect(abs(try frequency(low[Int(sampleRate * 0.5)...]) - 220) < 2)
        transport.semitones = Int.max
        #expect(transport.semitones == 12)
        let high = try render(transport, seconds: 1.5)
        #expect(abs(try frequency(high[Int(sampleRate * 0.5)...]) - 880) < 3)
    }

    @Test
    func pauseResumeAndSeekUseRenderedSourceTime() async throws {
        let clip = try sine(seconds: 8)
        let transport = try offline(clip)
        defer { transport.stop() }
        try transport.play()
        // A running transport with no rendered samples must not advance with wall time.
        try await Task.sleep(for: .milliseconds(20))
        #expect(transport.currentTime == 0)
        _ = try render(transport, seconds: 1)
        let running = transport.currentTime
        #expect(running > 0.8 && running <= 1)
        transport.pause()
        let paused = transport.currentTime
        #expect(!transport.isPlaying)
        try await Task.sleep(for: .milliseconds(20))
        #expect(transport.currentTime == paused)
        try transport.play()
        _ = try render(transport, seconds: 0.5)
        #expect(abs((transport.currentTime - paused) - 0.5) < 0.04)
        transport.seek(to: 4)
        #expect(transport.isPlaying)
        #expect(abs(transport.currentTime - 4) < 1 / sampleRate)
        _ = try render(transport, seconds: 0.75)
        #expect(transport.currentTime > 4.55 && transport.currentTime <= 4.75)
        transport.pause()
        transport.seek(to: 2)
        #expect(!transport.isPlaying)
        #expect(abs(transport.currentTime - 2) < 1 / sampleRate)
        try transport.play()
        _ = try render(transport, seconds: 0.5)
        #expect(transport.currentTime > 2.3 && transport.currentTime <= 2.5)
        transport.seek(to: .infinity)
        let unchanged = transport.currentTime
        transport.seek(to: .nan)
        #expect(transport.currentTime == unchanged)
        transport.seek(to: -100)
        #expect(transport.currentTime == 0)
        transport.seek(to: 100)
        #expect(!transport.isPlaying)
        #expect(transport.currentTime == transport.duration)
        try transport.play()
        #expect(transport.isPlaying)
        #expect(transport.currentTime == 0)
    }

    @Test
    func staleCompletionsCannotEndSeekedOrReplacementAudio() async throws {
        let clip = try sine(seconds: 1)
        let replacement = try sine(seconds: 5)
        let transport = try offline(clip)
        defer { transport.stop() }
        var ended = 0
        transport.onEnded = { ended += 1 }
        try transport.play()
        // Real node completion is enqueued, but cannot enter MainActor until this synchronous work exits.
        _ = try render(transport, seconds: 1.3)
        transport.seek(to: 0.25)
        try await Task.sleep(for: .milliseconds(20))
        #expect(transport.isPlaying)
        #expect(ended == 0)
        #expect(abs(transport.currentTime - 0.25) < 1 / sampleRate)
        _ = try render(transport, seconds: 1.1)
        transport.load(replacement)
        try transport.play()
        try await Task.sleep(for: .milliseconds(20))
        #expect(transport.isPlaying)
        #expect(transport.currentTime == 0)
        #expect(transport.duration == 5)
        #expect(ended == 0)
        _ = try render(transport, seconds: 5.3)
        try await allowCallbacks(transport, until: { ended == 1 })
        #expect(!transport.isPlaying)
        #expect(transport.currentTime == 5)
        try transport.play()
        #expect(transport.currentTime == 0)
        #expect(transport.isPlaying)
        _ = try render(transport, seconds: 5.3)
        try await allowCallbacks(transport, until: { ended == 2 })
        transport.stop()
        #expect(transport.currentTime == 0)
        #expect(!transport.isPlaying)
        #expect(transport.duration == 5)
    }

    @Test
    func exactEndOfFractionalDurationRestartsFromBeginning() throws {
        let clip = try DecodedAudio(samples: [Float](repeating: 0, count: 176_401), sampleRate: sampleRate)
        let transport = try offline(clip)
        defer { transport.stop() }
        transport.seek(to: clip.duration)
        #expect(transport.currentTime == clip.duration)
        #expect(!transport.isPlaying)
        try transport.play()
        #expect(transport.isPlaying)
        #expect(transport.currentTime == 0)
    }

    @Test
    func differentOutputSampleRatePreservesSourceSeconds() throws {
        let clip = try sine(seconds: 6)
        let transport = KaraokePlayback()
        defer { transport.stop() }
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try transport.engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: quantum)
        transport.load(clip)
        transport.semitones = -2
        try transport.play()
        _ = try render(transport, frames: 48_000)
        #expect(abs(transport.currentTime - 1) < 0.025)
        transport.semitones = 1
        _ = try render(transport, frames: 48_000)
        #expect(abs(transport.currentTime - 2) < 0.025)
        transport.pause()
        transport.seek(to: 3)
        try transport.play()
        _ = try render(transport, frames: 24_000)
        #expect(abs(transport.currentTime - 3.5) < 0.025)
    }

    @Test
    func schedulingViewsShareSamplesAndKeepTheClipAlive() throws {
        var clip: DecodedAudio? = try sine(seconds: 1)
        weak var retainedClip = clip
        var full: AVAudioPCMBuffer? = try #require(clip?.schedulingBuffer(startingAt: 0))
        var partial: AVAudioPCMBuffer? = try #require(clip?.schedulingBuffer(startingAt: 100))
        let base = try #require(full?.floatChannelData?[0])
        let tail = try #require(partial?.floatChannelData?[0])
        #expect(tail == base.advanced(by: 100))
        #expect(partial?.frameLength == (full?.frameLength ?? 0) - 100)
        clip = nil
        #expect(retainedClip != nil)
        #expect(tail[37] == base[137])
        full = nil
        #expect(retainedClip != nil)
        partial = nil
        #expect(retainedClip == nil)
    }

    @Test
    func invalidMP3AndDecodedSizeLimits() throws {
        for bytes in [Data(), Data([0, 1, 2, 3]), Data("ID3\u{4}\0\0\0\0\0\0not MPEG audio".utf8)] {
            #expect(throws: (any Error).self) { try DecodedAudio(mp3Data: bytes) }
        }
        let maximumMonoFrames = DecodedAudio.maximumPCMBytes / UInt64(MemoryLayout<Float>.size)
        #expect(try DecodedAudio.checkedCapacity(frames: maximumMonoFrames, channels: 1) == UInt32(maximumMonoFrames))
        #expect(throws: (any Error).self) {
            try DecodedAudio.checkedCapacity(frames: maximumMonoFrames + 1, channels: 1)
        }
        #expect(throws: (any Error).self) {
            try DecodedAudio.checkedCapacity(frames: UInt64.max, channels: 2)
        }
        #expect(throws: (any Error).self) {
            try DecodedAudio.checkedCapacity(frames: UInt64.max / 4, channels: UInt32.max)
        }
    }

    private enum TestFailure: Error {
        case emptyRender
        case renderUnavailable
    }
}
