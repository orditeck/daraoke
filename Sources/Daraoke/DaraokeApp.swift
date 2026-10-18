import AppKit
import SwiftUI

@main
struct DaraokeApp: App {
    @StateObject private var player = PlayerModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Daraoké", id: "player") {
            PlayerView(model: player)
                .frame(minWidth: 880, minHeight: 740)
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
            }
            CommandGroup(replacing: .appInfo) {
                Button("About Daraoké") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Daraoké",
                        .applicationVersion: "0.1.0",
                        .credits: NSAttributedString(string: "Your songs. Your stage.\nOpen-source karaoke for macOS.")
                    ])
                }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var player: PlayerModel?
    private var pendingURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
