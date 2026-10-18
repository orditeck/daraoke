import AppKit
import AVFoundation
import CDGCore
import Combine
import KaraokeImport
import UniformTypeIdentifiers

struct PlayingSong {
    let title: String
    let artist: String?
    let year: Int?
    let fileName: String
}

@MainActor
final class PlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var song: PlayingSong?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var frameRevision: UInt64 = 0
    @Published var errorMessage: String?
    @Published var volume: Double = 0.8 {
        didSet { audio?.volume = Float(volume) }
    }
    @Published var lyricsOffset: Double = 0 {
        didSet { updateGraphics() }
    }

    private(set) var decoder: CDGDecoder?
    private var audio: AVAudioPlayer?
    private var timer: Timer?
    private var lastRenderedRevision: UInt64?

    func chooseZip() {
        guard !isLoading else { return }
        let panel = NSOpenPanel()
        panel.title = "Open a karaoke ZIP"
        panel.message = "Choose a ZIP containing one MP3 and its CDG graphics."
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Open song"
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url { self?.open(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func openDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        guard !isLoading else { return false }
        guard providers.count == 1, let provider = providers.first else {
            errorMessage = "Drop one karaoke ZIP at a time."
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = item as? URL }
            Task { @MainActor [weak self] in
                if let url { self?.open(url) }
                else { self?.errorMessage = "This item is not a local ZIP file. Try Open ZIP instead." }
            }
        }
        return true
    }

    func open(_ url: URL) {
        guard !isLoading else { return }
        guard url.isFileURL, url.pathExtension.lowercased() == "zip" else {
            errorMessage = "Open a ZIP file containing an MP3 and its CDG graphics."
            return
        }
        isLoading = true
        errorMessage = nil
        let scopedAccess = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                isLoading = false
                if scopedAccess { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try SongImporter.load(zipURL: url)
                }.value
                let nextAudio: AVAudioPlayer
                do {
                    nextAudio = try AVAudioPlayer(data: imported.audioData, fileTypeHint: AVFileType.mp3.rawValue)
                    guard nextAudio.duration.isFinite, nextAudio.duration > 0, nextAudio.prepareToPlay() else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                } catch {
                    throw PlaybackError.invalidAudio
                }
                // Validate before stopping the current song: failed imports leave playback intact.
                stopTimer()
                audio?.stop()
                audio = nextAudio
                nextAudio.volume = Float(volume)
                nextAudio.delegate = self
                decoder = CDGDecoder(data: imported.cdgData)
                lastRenderedRevision = nil
                song = PlayingSong(title: imported.title, artist: imported.artist,
                                   year: imported.year, fileName: imported.fileName)
                duration = nextAudio.duration
                elapsed = 0
                lyricsOffset = 0
                updateGraphics()
                play()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func togglePlayback() {
        if isPlaying {
            audio?.pause()
            isPlaying = false
            stopTimer()
            refresh()
        } else {
            play()
        }
    }

    func play() {
        guard let audio else { return }
        if audio.currentTime >= duration - 0.02 {
            audio.currentTime = 0
            decoder?.reset()
        }
        guard audio.play() else {
            errorMessage = "The audio output could not start. Check your Mac’s sound output and try Play again."
            return
        }
        isPlaying = true
        startTimer()
        refresh()
    }

    func seek(to time: Double) {
        guard let audio, time.isFinite else { return }
        let target = min(max(0, time), duration)
        audio.currentTime = target
        elapsed = target
        if target >= duration {
            audio.pause()
            isPlaying = false
            stopTimer()
        }
        updateGraphics()
    }

    func skip(by seconds: Double) {
        seek(to: elapsed + seconds)
    }

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        guard let audio else { return }
        if abs(elapsed - audio.currentTime) >= 0.08 { elapsed = audio.currentTime }
        updateGraphics()
    }

    private func updateGraphics() {
        guard let decoder else { return }
        decoder.seek(to: max(0, (audio?.currentTime ?? elapsed) + lyricsOffset))
        if lastRenderedRevision != decoder.revision {
            lastRenderedRevision = decoder.revision
            frameRevision &+= 1
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let audio = self.audio, ObjectIdentifier(audio) == identity else { return }
            self.stopTimer()
            self.isPlaying = false
            self.elapsed = self.duration
            self.decoder?.seek(to: max(0, self.duration + self.lyricsOffset))
            self.frameRevision &+= 1
            if !flag { self.errorMessage = "Playback stopped because the audio could not be decoded." }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let audio = self.audio, ObjectIdentifier(audio) == identity else { return }
            self.stopTimer()
            self.isPlaying = false
            self.errorMessage = "The MP3 could not be decoded. Try another copy of this song."
        }
    }
}

private enum PlaybackError: LocalizedError {
    case invalidAudio

    var errorDescription: String? {
        "The MP3 is empty, damaged, or cannot be decoded. Try another copy of this karaoke ZIP."
    }
}
