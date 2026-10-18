import AVFoundation
import Foundation

/// Main-actor transport; all timestamps refer to the original source audio, never stretched time.
@MainActor
public final class KaraokePlayback {
    // Internal access lets tests render the exact production graph without an audio device.
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var observation: EngineObservation?
    private var clip: DecodedAudio?
    private var scheduledBuffer: AVAudioPCMBuffer?
    private var generation: UInt64 = 0
    private var scheduledStart: AVAudioFramePosition = 0
    private var restingFrame: AVAudioFramePosition = 0
    private var clockFrame: AVAudioFramePosition = 0
    private var renderedEndPending = false
    private var key = 0

    public private(set) var isPlaying = false
    public var onEnded: (@MainActor @Sendable () -> Void)?
    public var onError: (@MainActor @Sendable (String) -> Void)?
    public var duration: TimeInterval { clip?.duration ?? 0 }

    public var currentTime: TimeInterval {
        guard let clip else { return 0 }
        if isPlaying {
            updateClock()
            // Offline callbacks mean "rendered", not "heard". Drain the DSP tail before ending.
            if renderedEndPending, clockFrame >= clip.frameCount { finish() }
        }
        return Double(isPlaying ? clockFrame : restingFrame) / clip.format.sampleRate
    }

    public var volume: Float {
        get { player.volume }
        set {
            guard newValue.isFinite else { return }
            player.volume = min(1, max(0, newValue))
        }
    }

    public var semitones: Int {
        get { key }
        set {
            key = min(12, max(-12, newValue))
            timePitch.pitch = Float(key) * 100
            // Keep this graph (including its DSP latency) active at zero and during live changes.
            timePitch.rate = 1
        }
    }

    public init() {
        engine.attach(player)
        engine.attach(timePitch)
        timePitch.rate = 1
        timePitch.pitch = 0
        observation = EngineObservation(engine: engine) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying, !self.engine.isRunning else { return }
                self.outputStopped()
            }
        }
    }

    public func load(_ clip: DecodedAudio) {
        isPlaying = false
        invalidateSchedule()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(player, to: timePitch, format: clip.format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: clip.format)
        self.clip = clip
        restingFrame = 0
        clockFrame = 0
    }

    public func play() throws {
        guard let clip else { return }
        if isPlaying, engine.isRunning { return }
        if restingFrame >= clip.frameCount {
            invalidateSchedule()
            restingFrame = 0
            clockFrame = 0
        }
        if scheduledBuffer == nil {
            guard let buffer = clip.schedulingBuffer(startingAt: restingFrame) else {
                throw PlaybackOutputError.cannotSchedule
            }
            scheduledStart = restingFrame
            clockFrame = restingFrame
            renderedEndPending = false
            scheduledBuffer = buffer
            let identity = generation
            let callback: AVAudioPlayerNodeCompletionCallbackType = engine.isInManualRenderingMode
                ? .dataRendered : .dataPlayedBack
            player.scheduleBuffer(buffer, completionCallbackType: callback) { @Sendable [weak self] _ in
                // AVFoundation calls off-actor. Explicit Sendable prevents inherited MainActor
                // isolation before the hop; no AVFoundation object crosses that boundary.
                Task { @MainActor [weak self] in self?.completed(generation: identity) }
            }
        }
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            guard engine.isRunning else { throw PlaybackOutputError.cannotStart }
            if !player.isPlaying { player.play() }
            isPlaying = true
        } catch {
            // A failed start must be resumable from the same source position, not claim playback.
            invalidateSchedule()
            engine.stop()
            isPlaying = false
            throw PlaybackOutputError.cannotStart
        }
    }

    public func pause() {
        guard isPlaying else { return }
        updateClock()
        restingFrame = clockFrame
        // Freeze the entire graph. Pausing the node separately would anchor its resume
        // at TimePitch's read-ahead position, skipping the still-buffered source timeline.
        engine.pause()
        isPlaying = false
    }

    public func seek(to time: TimeInterval) {
        guard let clip, time.isFinite else { return }
        let resume = isPlaying
        isPlaying = false
        invalidateSchedule()
        let bounded = min(clip.duration, max(0, time))
        restingFrame = bounded >= clip.duration
            ? clip.frameCount
            : min(clip.frameCount, AVAudioFramePosition((bounded * clip.format.sampleRate).rounded(.down)))
        clockFrame = restingFrame
        if restingFrame >= clip.frameCount {
            engine.pause()
        } else if resume {
            do { try play() }
            catch { onError?(error.localizedDescription) }
        }
    }

    public func stop() {
        isPlaying = false
        invalidateSchedule()
        engine.stop()
        restingFrame = 0
        clockFrame = 0
    }

    private func updateClock() {
        guard let clip else { return }
        let rendered: AVAudioTime
        if engine.isInManualRenderingMode {
            // Manual rendering has an explicit output sample clock; mixer timestamps may be invalid.
            let seconds = Double(engine.manualRenderingSampleTime) / engine.manualRenderingFormat.sampleRate
            rendered = AVAudioTime(sampleTime: AVAudioFramePosition((seconds * clip.format.sampleRate).rounded(.down)),
                                   atRate: clip.format.sampleRate)
        } else {
            // Hardware player timestamps already use source-rate frames. The graph
            // reports its downstream DSP/device latency, unlike offline read-ahead.
            guard let sourceTime = player.lastRenderTime, sourceTime.isSampleTimeValid else { return }
            rendered = sourceTime
        }
        guard let source = player.playerTime(forNodeTime: rendered),
              source.isSampleTimeValid, source.sampleRate > 0 else { return }
        let downstream = max(player.outputPresentationLatency,
                             timePitch.latency + timePitch.outputPresentationLatency)
        let latency = downstream.isFinite ? max(0, downstream) : 0
        let played = max(0, Double(source.sampleTime) / source.sampleRate - latency)
        let frame = min(Double(clip.frameCount), Double(scheduledStart) + played * clip.format.sampleRate)
        // A latency re-estimate during a key change may hold the display briefly, never rewind CDG.
        clockFrame = max(clockFrame, AVAudioFramePosition(frame.rounded(.down)))
    }

    private func completed(generation identity: UInt64) {
        guard identity == generation, scheduledBuffer != nil else { return }
        if isPlaying, !engine.isRunning {
            outputStopped()
            return
        }
        if engine.isInManualRenderingMode {
            renderedEndPending = true
            if isPlaying {
                updateClock()
                if let clip, clockFrame >= clip.frameCount { finish() }
            }
        } else {
            finish()
        }
    }

    private func outputStopped() {
        updateClock()
        restingFrame = clockFrame
        invalidateSchedule()
        isPlaying = false
        onError?("The audio output changed or stopped. Check your Mac’s sound output and try Play again.")
    }

    private func finish() {
        guard let clip, scheduledBuffer != nil else { return }
        isPlaying = false
        invalidateSchedule()
        engine.pause()
        restingFrame = clip.frameCount
        clockFrame = clip.frameCount
        onEnded?()
    }

    private func invalidateSchedule() {
        // stop() itself invokes old completion handlers; invalidate them before touching the node.
        generation &+= 1
        player.stop()
        timePitch.reset()
        scheduledBuffer = nil
        renderedEndPending = false
    }
}

private final class EngineObservation: @unchecked Sendable {
    private let token: any NSObjectProtocol

    init(engine: AVAudioEngine, changed: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                       object: engine, queue: nil) { _ in changed() }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

private enum PlaybackOutputError: LocalizedError {
    case cannotSchedule
    case cannotStart

    var errorDescription: String? {
        switch self {
        case .cannotSchedule:
            "The decoded karaoke audio could not be scheduled for playback."
        case .cannotStart:
            "The audio output could not start. Check your Mac’s sound output and try Play again."
        }
    }
}
