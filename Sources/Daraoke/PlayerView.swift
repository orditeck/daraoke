import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let rose = Color(red: 1, green: 0.43, blue: 0.53)
private let muted = Color(red: 0.62, green: 0.62, blue: 0.69)
private let panel = Color(red: 0.095, green: 0.095, blue: 0.13)

struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    @State private var dropTarget = false
    @State private var showTiming = false

    var body: some View {
        VStack(spacing: 22) {
            header
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            transport
            footer
        }
        .padding(.horizontal, 36)
        .padding(.top, 36)
        .padding(.bottom, 20)
        .background(Color(red: 0.055, green: 0.055, blue: 0.08))
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $dropTarget, perform: model.openDroppedFiles)
        .alert("Couldn’t open this song", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
            Button("Choose another ZIP…") { model.errorMessage = nil; model.chooseZip() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(rose)
                .frame(width: 48, height: 48)
                .background(rose.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 3) {
                Text("Daraoké").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Your songs. Your stage.").font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            Label("LOCAL & OFFLINE", systemImage: "checkmark.shield")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(muted)
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(.white.opacity(0.035), in: Capsule())
        }
    }

    private var stage: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(model.isPlaying ? rose : muted.opacity(0.6)).frame(width: 6, height: 6)
                    Text(model.song == nil ? "THE STAGE IS YOURS" : model.isPlaying ? "ON STAGE" : "READY WHEN YOU ARE")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.6)
                }
                .foregroundStyle(muted)
                Spacer()
                Text("CD+G / MP3").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted.opacity(0.8))
            }
            ZStack {
                RoundedRectangle(cornerRadius: 22)
                    .fill(LinearGradient(colors: [panel, Color(red: 0.075, green: 0.065, blue: 0.10)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                if let decoder = model.decoder {
                    CDGCanvas(decoder: decoder, revision: model.frameRevision)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                } else {
                    emptyStage
                }
                if dropTarget || model.isLoading {
                    RoundedRectangle(cornerRadius: 22).fill(panel.opacity(0.95))
                    VStack(spacing: 16) {
                        if model.isLoading {
                            ProgressView().controlSize(.large).tint(rose)
                            Text("Setting the stage…").font(.system(size: 22, weight: .semibold, design: .rounded))
                        } else {
                            Image(systemName: "arrow.down.doc.fill").font(.system(size: 38)).foregroundStyle(rose)
                            Text("Drop it like it’s a hit.").font(.system(size: 24, weight: .semibold, design: .rounded))
                        }
                    }
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(dropTarget ? rose : .white.opacity(0.07), lineWidth: dropTarget ? 2 : 1)
            }
        }
    }

    private var emptyStage: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle().stroke(rose.opacity(0.07), lineWidth: 1).frame(width: 112, height: 112)
                Circle().fill(rose.opacity(0.06)).frame(width: 84, height: 84)
                Image(systemName: "music.mic").font(.system(size: 36, weight: .light)).foregroundStyle(rose)
                Image(systemName: "sparkle").font(.system(size: 15)).foregroundStyle(rose.opacity(0.65)).offset(x: 42, y: -31)
            }
            .padding(.bottom, 20)
            Text("Make room for your voice.")
                .font(.system(size: 29, weight: .semibold, design: .rounded))
                .padding(.bottom, 9)
            Text("Drop a karaoke ZIP. We’ll take it from here.")
                .font(.system(size: 14)).foregroundStyle(muted)
                .padding(.bottom, 27)
            Button(action: model.chooseZip) {
                Label("Open a karaoke ZIP", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 22).padding(.vertical, 12)
            }
            .buttonStyle(RoseButtonStyle())
            .disabled(model.isLoading)
            .padding(.bottom, 18)
            Text("ONE MP3 + ONE CDG · NO UNZIPPING NEEDED")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.1).foregroundStyle(muted.opacity(0.75))
        }
        .padding(28)
    }

    private var transport: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 22)).foregroundStyle(rose)
                    .frame(width: 46, height: 46)
                    .background(rose.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.song?.title ?? "Your next favorite moment")
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(model.song.map { [$0.artist, $0.year.map(String.init)].compactMap { $0 }.joined(separator: " · ") }
                         .flatMap { $0.isEmpty ? nil : $0 } ?? "A little courage. A lot of karaoke.")
                        .font(.system(size: 12)).foregroundStyle(muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button(action: model.chooseZip) {
                    Label("Open ZIP", systemImage: "folder.badge.plus").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(model.isLoading)
                .help("Open another karaoke ZIP (⌘O)")
            }
            VStack(spacing: 3) {
                Slider(value: Binding(get: { model.elapsed }, set: { model.seek(to: $0) }),
                       in: 0...max(1, model.duration))
                    .tint(rose).disabled(model.song == nil)
                    .accessibilityLabel("Song position")
                    .accessibilityValue("\(timecode(model.elapsed)) of \(timecode(model.duration))")
                HStack {
                    Text(timecode(model.elapsed)).accessibilityLabel("Elapsed time")
                    Spacer()
                    Text("−" + timecode(max(0, model.duration - model.elapsed))).accessibilityLabel("Time remaining")
                }
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                .monospacedDigit()
            }
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                        .font(.system(size: 13)).foregroundStyle(muted)
                    Slider(value: $model.volume, in: 0...1)
                        .tint(muted).frame(width: 90)
                        .accessibilityLabel("Volume")
                        .accessibilityValue("\(Int(model.volume * 100)) percent")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 22) {
                    TransportButton(symbol: "backward.end.fill", label: "Restart song") { model.seek(to: 0) }
                    TransportButton(symbol: "gobackward.10", label: "Back 10 seconds") { model.skip(by: -10) }
                    Button(action: model.togglePlayback) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 21, weight: .semibold))
                            .offset(x: model.isPlaying ? 0 : 2)
                            .frame(width: 58, height: 58)
                    }
                    .buttonStyle(RoseButtonStyle())
                    .clipShape(Circle())
                    .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                    .help("Play / pause (Space)")
                    TransportButton(symbol: "goforward.10", label: "Forward 10 seconds") { model.skip(by: 10) }
                    TransportButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Toggle fullscreen") { model.toggleFullscreen() }
                }
                .disabled(model.song == nil)
                HStack(spacing: 6) {
                    Button { showTiming.toggle() } label: {
                        Label("Timing", systemImage: "slider.horizontal.3").font(.system(size: 12))
                            .foregroundStyle(model.lyricsOffset == 0 ? muted : rose)
                            .padding(9)
                    }
                    .buttonStyle(.plain)
                    .help("Adjust lyrics synchronization")
                    .disabled(model.song == nil)
                    .popover(isPresented: $showTiming) { timingPanel }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var timingPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lyrics timing").font(.headline)
            Text("Fix an offset in the source files. Positive values show lyrics earlier.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Slider(value: $model.lyricsOffset, in: -3...3, step: 0.1).tint(rose)
                    .accessibilityLabel("Lyrics offset")
                Text(String(format: "%+.1f s", model.lyricsOffset)).monospacedDigit().frame(width: 55)
            }
            Button("Reset to zero") { model.lyricsOffset = 0 }
        }
        .padding(20).frame(width: 300)
    }

    private var footer: some View {
        HStack {
            Text("DARAOKÉ  /  ZIP PLAYER").tracking(1.2)
            Spacer()
            Text("SPACE  Play / pause     ← →  Seek     ⌘O  Open")
        }
        .font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(muted.opacity(0.65))
    }

}

private struct TransportButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .frame(width: 26, height: 34).foregroundStyle(.white.opacity(0.8))
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

private struct RoseButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(red: 0.15, green: 0.045, blue: 0.065))
            .background(rose.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 11))
            .opacity(isEnabled ? 1 : 0.35)
    }
}

private func timecode(_ seconds: Double) -> String {
    let value = seconds.isFinite ? max(0, Int(seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}
