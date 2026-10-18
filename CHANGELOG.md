# Changelog

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
