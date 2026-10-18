import AppKit
import Combine
import SwiftUI

@main
struct DaraokeApp: App {
    @StateObject private var player = PlayerModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Daraoké", id: "player") {
            PlayerView(model: player)
                .frame(minWidth: 880, minHeight: 740)
                .background(PlayerWindowReference(attach: delegate.bindWindow))
                .toolbar(removing: .sidebarToggle)
                .onAppear {
                    delegate.attach(player)
                }
                .onOpenURL { player.open($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1060, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Karaoke ZIP…", action: player.chooseZip)
                    .keyboardShortcut("o")
                    .disabled(player.isLoading)
            }
            CommandGroup(replacing: .toolbar) { }
            CommandGroup(replacing: .sidebar) { }
            FullscreenCommands(delegate: delegate)
            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play", action: player.togglePlayback)
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(player.song == nil)
                Button("Restart Song") { player.seek(to: 0) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(player.song == nil)
                Divider()
                Button("Back 5 Seconds") { player.skip(by: -5) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(player.song == nil)
                Button("Forward 5 Seconds") { player.skip(by: 5) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(player.song == nil)
                Divider()
                Menu("Key") {
                    Button("Lower") { player.changeKey(by: -1) }
                        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                        .disabled(player.song == nil || player.keyShift <= -12)
                    Button("Higher") { player.changeKey(by: 1) }
                        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                        .disabled(player.song == nil || player.keyShift >= 12)
                    Button("Original", action: player.resetKey)
                        .keyboardShortcut("0", modifiers: [.command, .option])
                        .disabled(player.song == nil)
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Daraoké") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Daraoké",
                        .applicationVersion: "0.1.2",
                        .credits: NSAttributedString(string: "Your songs. Your stage.\nOpen-source karaoke for macOS.")
                    ])
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    private weak var player: PlayerModel?
    private var pendingURL: URL?
    private weak var playerWindow: NSWindow?
    @Published private(set) var isFullscreen = false
    @Published private(set) var canToggleFullscreen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func bindWindow(_ window: NSWindow?) {
        guard playerWindow !== window else { return }
        if let previous = playerWindow {
            NotificationCenter.default.removeObserver(self, name: nil, object: previous)
        }
        playerWindow = window
        if let window {
            let notifications: [Notification.Name] = [
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification,
                NSWindow.willCloseNotification
            ]
            for name in notifications {
                NotificationCenter.default.addObserver(self, selector: #selector(windowStateChanged(_:)),
                                                       name: name, object: window)
            }
        }
        updateWindowState()
    }

    func toggleFullscreen() {
        playerWindow?.toggleFullScreen(nil)
    }

    @objc private func windowStateChanged(_ notification: Notification) {
        if notification.name == NSWindow.willCloseNotification {
            canToggleFullscreen = false
            isFullscreen = false
        } else if notification.name == NSWindow.willBeginSheetNotification {
            canToggleFullscreen = false
        } else {
            updateWindowState()
        }
    }

    private func updateWindowState() {
        isFullscreen = playerWindow?.styleMask.contains(.fullScreen) ?? false
        canToggleFullscreen = playerWindow.map {
            $0.isVisible && !$0.isMiniaturized && $0.attachedSheet == nil
        } ?? false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let player { player.open(url) }
        else { pendingURL = url }
    }

    func attach(_ player: PlayerModel) {
        self.player = player
        if let pendingURL {
            self.pendingURL = nil
            player.open(pendingURL)
        } else if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") && $0.lowercased().hasSuffix(".zip") }) {
            player.open(URL(fileURLWithPath: path))
        }
    }
}

private struct FullscreenCommands: Commands {
    @ObservedObject var delegate: AppDelegate

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(delegate.isFullscreen ? "Exit Full Screen" : "Enter Full Screen",
                   action: delegate.toggleFullscreen)
                .keyboardShortcut("f", modifiers: [.command, .control])
                .disabled(!delegate.canToggleFullscreen)
        }
    }
}

private struct PlayerWindowReference: NSViewRepresentable {
    let attach: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> WindowReferenceView {
        let view = WindowReferenceView()
        view.attach = attach
        return view
    }

    func updateNSView(_ view: WindowReferenceView, context: Context) {
        view.attach = attach
        attach(view.window)
    }
}

private final class WindowReferenceView: NSView {
    var attach: (@MainActor (NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach?(window)
    }
}
