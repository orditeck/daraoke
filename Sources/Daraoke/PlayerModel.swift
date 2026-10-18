import AppKit
import KaraokeAudio
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
final class PlayerModel: ObservableObject {
    @Published private(set) var song: PlayingSong?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var frameRevision: UInt64 = 0
    @Published private(set) var keyShift = 0
    @Published var errorMessage: String?
    @Published var volume: Double = 0.8 {
        didSet { audio.volume = Float(volume) }
    }
    @Published var lyricsOffset: Double = 0 {
        didSet { updateGraphics() }
    }

    private(set) var decoder: CDGDecoder?
    private let audio = KaraokePlayback()
    private var timer: Timer?
    private var lastRenderedRevision: UInt64?

    init() {
        audio.onEnded = { [weak self] in
            guard let self else { return }
            self.stopTimer()
            self.isPlaying = false
            self.elapsed = self.duration
            self.updateGraphics()
        }
        audio.onError = { [weak self] message in
            guard let self else { return }
            self.stopTimer()
            self.isPlaying = false
            self.refresh()
            self.errorMessage = message
        }
    }

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
                let (imported, decoded) = try await Task.detached(priority: .userInitiated) {
                    let imported = try SongImporter.load(zipURL: url)
                    return (imported, try DecodedAudio(mp3Data: imported.audioData))
                }.value
                // Import and decode before stopping the current song.
                stopTimer()
                audio.load(decoded)
                audio.volume = Float(volume)
                resetKey()
                decoder = CDGDecoder(data: imported.cdgData)
                lastRenderedRevision = nil
                song = PlayingSong(title: imported.title, artist: imported.artist,
                                   year: imported.year, fileName: imported.fileName)
                duration = decoded.duration
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
            audio.pause()
            isPlaying = false
            stopTimer()
            refresh()
        } else {
            play()
        }
    }

    func play() {
        guard song != nil else { return }
        if audio.currentTime >= duration - 0.02 {
            audio.seek(to: 0)
            decoder?.reset()
        }
        do {
            try audio.play()
        } catch {
            errorMessage = "The audio output could not start. Check your Mac’s sound output and try Play again. \(error.localizedDescription)"
            return
        }
        isPlaying = true
        startTimer()
        refresh()
    }

    func seek(to time: Double) {
        guard song != nil, time.isFinite else { return }
        let target = min(max(0, time), duration)
        audio.seek(to: target)
        elapsed = target
        isPlaying = audio.isPlaying
        if !isPlaying {
            stopTimer()
        }
        updateGraphics()
    }

    func skip(by seconds: Double) {
        seek(to: elapsed + seconds)
    }

    func changeKey(by semitones: Int) {
        guard song != nil else { return }
        keyShift = min(12, max(-12, keyShift + semitones))
        audio.semitones = keyShift
    }

    func resetKey() {
        keyShift = 0
        audio.semitones = 0
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
        if abs(elapsed - audio.currentTime) >= 0.08 { elapsed = audio.currentTime }
        updateGraphics()
    }

    private func updateGraphics() {
        guard let decoder else { return }
        decoder.seek(to: max(0, audio.currentTime + lyricsOffset))
        if lastRenderedRevision != decoder.revision {
            lastRenderedRevision = decoder.revision
            frameRevision &+= 1
        }
    }

}

