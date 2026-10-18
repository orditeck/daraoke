# Changelog

## 0.1.2 — 2026-10-18

### Added

- Double-click the karaoke stage to enter or leave native fullscreen, with or without a song loaded. Letterboxing is clickable too; single clicks and transport controls do not toggle fullscreen.

### Fixed

- The key-lowering minus button now responds across its full rectangular hit area instead of only the thin glyph. Plus and reset use the same full-frame hit targets.

## 0.1.1 — 2026-10-18

### Added

- Live key adjustment from −12 to +12 semitones without changing tempo or the CD+G timeline. −1 lowers by half a tone; −2 lowers by one tone; 0 restores the original key.
- Native − / value / + controls, click-to-reset, and Playback → Key commands with Option-Command-Down/Up/0 shortcuts.
- In-memory MP3-to-PCM decoding and an AVAudioEngine/TimePitch graph with a rendered-source clock and reported output/DSP latency compensation.
- Synthetic DSP regressions measuring output pitch, audible duration, burst timing, and transport transitions.

### Fixed

- Empty View menu. View now has one Enter/Exit Full Screen action with Control-Command-F; it follows the window state and survives playback/key changes and native menu rebuilds.
- Main-actor isolation at the AVFoundation completion boundary, and clock reads before the first valid render timestamp.
- Seeking to the exact end of a fractional-duration track now lands on the final frame and Play correctly restarts from zero.

## 0.1.0 — 2026-10-18

### Added

- Native macOS 14+ SwiftUI/AppKit karaoke player with AVFoundation MP3 playback.
- Drag-and-drop and file-picker import of an MP3/CDG pair from a ZIP, without extracting it to disk.
- Basic CD+G decoding, including both palette tables, normal/XOR tiles, scrolling, borders, and transparency.
- Audio-clock synchronization, deterministic seeking, playback/volume controls, native fullscreen, and lyric-offset adjustment.
- Bounded streaming imports, checksum validation, metadata display, and recoverable missing/corrupt-file errors that preserve the current song.
- Synthetic Swift Testing regressions and reproducible Apple Silicon/Intel app packaging.

### Known limits

- Single-song playback only; library features are tracked in GitHub milestones.
- Builds are ad-hoc signed and not notarized.
- macOS only. Linux/mobile support requires separate platform work.
- Basic CD+G only; unsupported ID3 variants fall back to filenames. See README for archive and resource limits.
