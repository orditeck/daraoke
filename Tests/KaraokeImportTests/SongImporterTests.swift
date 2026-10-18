import Foundation
import Testing
import ZIPFoundation
@testable import KaraokeImport

struct SongImporterTests {
    private final class Fixtures {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    // Swift Testing creates a fresh suite instance for each test; its fixture owns cleanup.
    private let fixtures = Fixtures()
    private var cdg: Data {
        var bytes = Data(repeating: 0, count: 24)
        bytes[0] = 9
        bytes[1] = 1 // Memory preset: a complete graphics instruction.
        return bytes
    }

    private func zip(_ entries: [(String, Data)], symlink: String? = nil,
                     compressed: Bool = false) throws -> URL {
        let directory = fixtures.directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("song.zip")
        let archive = try Archive(url: url, accessMode: .create)
        for (path, bytes) in entries {
            try archive.addEntry(with: path, type: path == symlink ? .symlink : .file,
                                 uncompressedSize: Int64(bytes.count),
                                 compressionMethod: compressed ? .deflate : .none) { position, count in
                let start = Int(position)
                return bytes.subdata(in: start..<min(start + count, bytes.count))
            }
        }
        return url
    }

    private func failure(_ url: URL, containing text: String? = nil,
                         sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try SongImporter.load(zipURL: url)
            Issue.record("Expected ZIP import to fail", sourceLocation: sourceLocation)
        } catch {
            if let text {
                #expect(error.localizedDescription.localizedCaseInsensitiveContains(text),
                        "Unexpected error: \(error.localizedDescription)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test
    func testUppercaseNestedPairIgnoresHiddenAndAppleMetadata() throws {
        let audio = Data([1, 2, 3])
        let url = try zip([
            ("Album/ARTIST - TITLE.MP3", audio), ("album/artist - title.CDG", cdg),
            ("__MACOSX/duplicate.mp3", audio), ("__MACOSX/duplicate.cdg", cdg),
            ("Album/._ARTIST - TITLE.MP3", audio), (".hidden/duplicate.cdg", cdg),
            ("Album/.invisible.mp3", audio)
        ], compressed: true)
        let song = try SongImporter.load(zipURL: url)
        #expect(song.title == "TITLE")
        #expect(song.artist == "ARTIST")
        #expect(song.year == nil)
        #expect(song.fileName == "ARTIST - TITLE.MP3")
        #expect(song.audioData == audio)
        #expect(song.cdgData == cdg)
    }

    @Test
    func testSingleMismatchedPairIsAccepted() throws {
        let song = try SongImporter.load(zipURL: zip([("sound.mp3", Data([1])), ("lyrics.cdg", cdg)]))
        #expect(song.title == "sound")
        #expect(song.artist == nil)
        #expect(song.year == nil)
    }

    @Test
    func testFullFolderStemsDoNotMatchUnrelatedSongs() throws {
        let url = try zip([("one/song.mp3", Data([1])), ("two/song.cdg", cdg),
                           ("other.mp3", Data([2])), ("third.cdg", cdg)])
        failure(url, containing: "ambiguous")
    }

    @Test
    func testMultiplePairsAreAmbiguous() throws {
        failure(try zip([("a.mp3", Data([1])), ("a.cdg", cdg),
                         ("b.mp3", Data([2])), ("b.cdg", cdg)]), containing: "ambiguous")
    }

    @Test
    func testSingleMatchedPairCanIgnoreUnmatchedExtras() throws {
        let song = try SongImporter.load(zipURL: zip([("a.mp3", Data([1])), ("a.cdg", cdg),
                                                      ("extra.mp3", Data([2]))]))
        #expect(song.title == "a")
    }

    @Test
    func testCanonicalUnicodeStemsMatch() throws {
        let song = try SongImporter.load(zipURL: zip([("caf\u{e9}.mp3", Data([1])),
                                                      ("cafe\u{301}.CDG", cdg), ("extra.mp3", Data([2]))]))
        #expect(song.title == "caf\u{e9}")
    }

    private func tag(version: UInt8 = 3, fields: [(String, UInt8, String)]) -> Data {
        var frames = Data()
        for (name, encoding, text) in fields {
            let format: String.Encoding = encoding == 1 ? .utf16 : encoding == 0 ? .isoLatin1 : .utf8
            var payload = Data([encoding])
            payload.append(text.data(using: format)!)
            frames.append(Data(name.utf8))
            let size = payload.count
            frames.append(contentsOf: version == 4 ? syncSafe(size) : [UInt8((size >> 24) & 255), UInt8((size >> 16) & 255), UInt8((size >> 8) & 255), UInt8(size & 255)])
            frames.append(contentsOf: [0, 0])
            frames.append(payload)
        }
        var result = Data([73, 68, 51, version, 0, 0])
        result.append(contentsOf: syncSafe(frames.count))
        result.append(frames)
        result.append(1) // MP3 decoding is intentionally the native player's responsibility.
        return result
    }

    private func syncSafe(_ size: Int) -> [UInt8] {
        [UInt8((size >> 21) & 127), UInt8((size >> 14) & 127), UInt8((size >> 7) & 127), UInt8(size & 127)]
    }

    @Test
    func testID3v23UTF16Latin1AndYear() throws {
        let audio = tag(fields: [("TIT2", 1, "Étoile"), ("TPE1", 0, "Björk"), ("TYER", 0, "1997")])
        let song = try SongImporter.load(zipURL: zip([("Wrong - Name.mp3", audio), ("Wrong - Name.cdg", cdg)]))
        #expect(song.title == "Étoile")
        #expect(song.artist == "Björk")
        #expect(song.year == 1997)
    }

    @Test
    func testID3v24UTF8DateAndMalformedYear() throws {
        let audio = tag(version: 4, fields: [("TIT2", 3, "星"), ("TPE1", 3, "Artist"), ("TDRC", 3, "2024-04-01")])
        let song = try SongImporter.load(zipURL: zip([("a.mp3", audio), ("a.cdg", cdg)]))
        #expect(song.title == "星")
        #expect(song.year == 2024)
        let invalid = tag(fields: [("TYER", 3, "nope")])
        let invalidSong = try SongImporter.load(zipURL: zip([("2001.mp3", invalid), ("2001.cdg", cdg)]))
        #expect(invalidSong.year == nil)
    }

    @Test
    func testID3v1FallbackAndExactFilenameSplit() throws {
        var audio = Data([1])
        var v1 = Data(repeating: 0, count: 128)
        v1.replaceSubrange(0..<3, with: Data("TAG".utf8))
        v1.replaceSubrange(3..<8, with: Data("Title".utf8))
        v1.replaceSubrange(33..<39, with: Data("Artist".utf8))
        v1.replaceSubrange(93..<97, with: Data("1984".utf8))
        audio.append(v1)
        let song = try SongImporter.load(zipURL: zip([("a.mp3", audio), ("a.cdg", cdg)]))
        #expect(song.title == "Title")
        #expect(song.artist == "Artist")
        #expect(song.year == 1984)
        let fallback = try SongImporter.load(zipURL: zip([("A - B - C.mp3", Data([1])), ("a.cdg", cdg)]))
        #expect(fallback.title == "A - B - C")
        #expect(fallback.artist == nil)
    }

    @Test
    func testMalformedBoundedTagsFallBackSafely() throws {
        let malformed = Data([73, 68, 51, 4, 0, 0, 127, 127, 127, 127, 0])
        let song = try SongImporter.load(zipURL: zip([("Artist - Title.mp3", malformed), ("x.cdg", cdg)]))
        #expect(song.title == "Title")
        #expect(song.artist == "Artist")
        #expect(song.year == nil)
    }

    @Test
    func testMissingSourceExplainsExternalDriveRecovery() {
        failure(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), containing: "Reconnect")
    }

    @Test
    func testEmptyMissingAndInvalidCDG() throws {
        failure(try zip([("a.mp3", Data()), ("a.cdg", cdg)]), containing: "empty")
        failure(try zip([("a.mp3", Data([1]))]), containing: "CDG")
        for invalid in [Data(), Data([9, 1]), Data(repeating: 0, count: 24)] {
            failure(try zip([("a.mp3", Data([1])), ("a.cdg", invalid)]), containing: "CDG")
        }
        var invalidTile = cdg
        invalidTile[1] = 6
        invalidTile[6] = 31
        failure(try zip([("a.mp3", Data([1])), ("a.cdg", invalidTile)]), containing: "CDG")
    }

    @Test
    func testSymlinkSongRejected() throws {
        failure(try zip([("a.mp3", Data("elsewhere".utf8)), ("a.cdg", cdg)], symlink: "a.mp3"), containing: "symbolic")
    }

    private func mutate(_ url: URL, _ change: (inout Data) -> Void) throws {
        var bytes = try Data(contentsOf: url)
        change(&bytes)
        try bytes.write(to: url)
    }

    private func put(_ value: UInt32, into bytes: inout Data, at offset: Int, count: Int = 4) {
        for index in 0..<count { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private func centralOffsets(_ bytes: Data) -> [Int] {
        // Generated fixture payloads contain no central-header signature.
        (0..<max(0, bytes.count - 3)).filter {
            bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4b && bytes[$0 + 2] == 1 && bytes[$0 + 3] == 2
        }
    }

    @Test
    func testCorruptArchiveAndCRCRejected() throws {
        let url = try zip([("a.mp3", Data([1, 2, 3])), ("a.cdg", cdg)])
        try mutate(url) { bytes in bytes[30 + "a.mp3".utf8.count] ^= 0xff }
        failure(url, containing: "CRC")
        try Data([0, 1, 2]).write(to: url)
        failure(url, containing: "corrupt")
    }

    @Test
    func testEntryCountLimitWithoutThousandsOfEntries() throws {
        let url = try zip([("a.mp3", Data([1])), ("a.cdg", cdg)])
        try mutate(url) { bytes in
            let end = bytes.count - 22
            put(4_097, into: &bytes, at: end + 8, count: 2)
            put(4_097, into: &bytes, at: end + 10, count: 2)
        }
        failure(url, containing: "4096")
    }

    @Test
    func testDeclaredAudioAndCDGLimitsWithoutLargeAllocation() throws {
        for (entryIndex, limit) in [(0, 128 * 1_024 * 1_024), (1, 32 * 1_024 * 1_024)] {
            let url = try zip([("a.mp3", Data([1])), ("a.cdg", cdg)])
            try mutate(url) { bytes in
                let header = centralOffsets(bytes)[entryIndex]
                let local = Int(bytes[header + 42]) | Int(bytes[header + 43]) << 8
                put(UInt32(limit + 1), into: &bytes, at: header + 24)
                put(UInt32(limit + 1), into: &bytes, at: local + 22)
            }
            failure(url, containing: "size limit")
        }
    }

    @Test
    func testArchiveLimitUsingSparseFile() throws {
        let url = try zip([])
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(512 * 1_024 * 1_024 + 1))
        try file.close()
        failure(url, containing: "512 MiB")
    }

    @Test
    func testEncryptionAndUnsupportedCompressionRejected() throws {
        for encrypted in [true, false] {
            let url = try zip([("a.mp3", Data([1])), ("a.cdg", cdg)])
            try mutate(url) { bytes in
                let header = centralOffsets(bytes)[0]
                if encrypted {
                    bytes[header + 8] |= 1
                    bytes[6] |= 1
                } else {
                    put(99, into: &bytes, at: header + 10, count: 2)
                    put(99, into: &bytes, at: 8, count: 2)
                }
            }
            failure(url, containing: encrypted ? "Encrypted" : "compression")
        }
    }

    @Test
    func testInflationCannotExceedDeclaredLength() throws {
        let url = try zip([("a.mp3", Data(repeating: 42, count: 4_096)), ("a.cdg", cdg)], compressed: true)
        try mutate(url) { bytes in
            let header = centralOffsets(bytes)[0]
            put(1, into: &bytes, at: header + 24)
            put(1, into: &bytes, at: 22)
        }
        failure(url)
    }

    @Test
    func testTruncatedDirectoryAndDisagreeingHeadersRejected() throws {
        let truncated = try zip([("a.mp3", Data([1])), ("a.cdg", cdg)])
        try mutate(truncated) { bytes in bytes.removeLast(5) }
        failure(truncated)
        let mismatch = try zip([("a.mp3", Data([1])), ("a.cdg", cdg)])
        try mutate(mismatch) { bytes in bytes[30] = Character("b").asciiValue! }
        failure(mismatch, containing: "filenames")
    }

    @Test
    func testValidCDGSurvivesMalformedPacketsAndPartialTail() throws {
        var invalidTile = cdg
        invalidTile[1] = 6
        invalidTile[6] = 31
        var invalidScroll = cdg
        invalidScroll[1] = 20
        invalidScroll[5] = 0x3f
        failure(try zip([("a.mp3", Data([1])), ("a.cdg", invalidScroll)]), containing: "CDG")
        var stream = invalidTile
        stream.append(invalidScroll)
        stream.append(cdg)
        stream.append(contentsOf: [9, 6, 0, 0, 0])
        let song = try SongImporter.load(zipURL: zip([("a.mp3", Data([1])), ("a.cdg", stream)]))
        #expect(song.cdgData == stream)
    }
}
