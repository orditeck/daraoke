import Foundation
import ZIPFoundation

public enum SongImporter {
    private static let archiveLimit = 512 * 1_024 * 1_024
    private static let audioLimit = 128 * 1_024 * 1_024
    private static let cdgLimit = 32 * 1_024 * 1_024

    private struct ImportError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    public static func load(zipURL: URL) throws -> ImportedSong {
        guard zipURL.isFileURL, FileManager.default.isReadableFile(atPath: zipURL.path) else {
            throw ImportError("The source ZIP is unavailable. Reconnect the external drive and retry opening the song.")
        }
        do {
            let records = try inspectArchive(zipURL)
            let archive = try Archive(url: zipURL, accessMode: .read)
            var audio: [String: [Entry]] = [:]
            var graphics: [String: [Entry]] = [:]
            var count = 0
            for entry in archive {
                guard count < records.count else { throw ImportError("The ZIP directory is corrupt.") }
                let record = records[count]
                count += 1
                guard entry.uncompressedSize == record.size, entry.compressedSize == record.compressed,
                      entry.checksum == record.crc else { throw ImportError("The ZIP entry headers disagree.") }
                let path = entry.path.replacingOccurrences(of: "\\", with: "/")
                let components = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !components.contains(where: { $0.hasPrefix(".") || $0.lowercased() == "__macosx" }) else { continue }
                let ext = (path as NSString).pathExtension.lowercased()
                guard ext == "mp3" || ext == "cdg" else { continue }
                guard entry.type == .file else { throw ImportError("Song entries must be regular files, not symbolic links or directories.") }
                guard !path.hasPrefix("/"), !components.contains(".."), !components.contains("") else {
                    throw ImportError("The ZIP contains an invalid song path.")
                }
                let stem = (path as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping.lowercased()
                if ext == "mp3" { audio[stem, default: []].append(entry) }
                else { graphics[stem, default: []].append(entry) }
            }
            guard count == records.count else { throw ImportError("The ZIP is corrupt, encrypted, or contains unsupported entries.") }
            let allAudio = audio.values.flatMap { $0 }
            let allGraphics = graphics.values.flatMap { $0 }
            guard !allAudio.isEmpty, !allGraphics.isEmpty else { throw ImportError("The ZIP must contain an MP3 audio file and a CDG graphics file.") }
            let mp3: Entry
            let cdg: Entry
            if allAudio.count == 1 && allGraphics.count == 1 {
                mp3 = allAudio[0]
                cdg = allGraphics[0]
            } else {
                let matches = Set(audio.keys).intersection(graphics.keys)
                guard matches.count == 1, let key = matches.first,
                      let sounds = audio[key], sounds.count == 1,
                      let pictures = graphics[key], pictures.count == 1 else {
                    throw ImportError("This ZIP is ambiguous: it contains multiple possible songs. Open a ZIP containing one MP3/CDG pair.")
                }
                mp3 = sounds[0]
                cdg = pictures[0]
            }
            let audioData = try read(mp3, from: archive, limit: audioLimit)
            let cdgData = try read(cdg, from: archive, limit: cdgLimit)
            guard !audioData.isEmpty else { throw ImportError("The MP3 audio file is empty.") }
            try validateCDG(cdgData)
            let fileName = (mp3.path.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            let stem = (fileName as NSString).deletingPathExtension
            let parts = stem.components(separatedBy: " - ")
            let fallbackArtist = parts.count == 2 ? clean(parts[0]) : nil
            let fallbackTitle = parts.count == 2 ? clean(parts[1]) ?? stem : stem
            let tags = metadata(audioData)
            return ImportedSong(title: tags.title ?? fallbackTitle, artist: tags.artist ?? fallbackArtist,
                                year: tags.year, fileName: fileName, audioData: audioData, cdgData: cdgData)
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError("Unable to read the ZIP song (corrupt, encrypted, unsupported, or disconnected source). Reconnect the drive if needed and retry. \(error.localizedDescription)")
        }
    }

    private static func read(_ entry: Entry, from archive: Archive, limit: Int) throws -> Data {
        guard entry.uncompressedSize <= UInt64(limit) else { throw ImportError("The \((entry.path as NSString).pathExtension.uppercased()) file exceeds the import size limit.") }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        let crc = try archive.extract(entry, bufferSize: 64 * 1_024) { chunk in
            guard chunk.count <= limit - result.count,
                  UInt64(result.count + chunk.count) <= entry.uncompressedSize else {
                throw ImportError("The ZIP expands beyond its declared size or import limit.")
            }
            result.append(chunk)
        }
        guard result.count == Int(entry.uncompressedSize), crc == entry.checksum else {
            throw ImportError("The ZIP file is corrupt: its size or CRC checksum does not match.")
        }
        return result
    }

    private struct Record {
        let size: UInt64
        let compressed: UInt64
        let crc: UInt32
    }

    // ZIPFoundation deliberately ends iteration at unsupported/encrypted records. Inspect the
    // bounded directory first so a partial archive can never masquerade as a complete song.
    private static func inspectArchive(_ url: URL) throws -> [Record] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= UInt64(archiveLimit) else { throw ImportError("The ZIP exceeds the 512 MiB archive limit.") }
        guard size >= 22 else { throw ImportError("The ZIP is corrupt or empty.") }
        func bytes(at offset: UInt64, count: Int) throws -> Data {
            guard offset <= size, UInt64(count) <= size - offset else { throw ImportError("The ZIP is truncated.") }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else { throw ImportError("The ZIP is truncated.") }
            return data
        }
        let tailSize = Int(min(size, 65_557))
        let tail = try bytes(at: size - UInt64(tailSize), count: tailSize)
        let end = stride(from: tail.count - 22, through: 0, by: -1).first {
            number(tail, $0, 4) == 0x06054b50 && $0 + 22 + Int(number(tail, $0 + 20, 2)) == tail.count
        }
        guard let end else { throw ImportError("The ZIP end directory is missing or corrupt.") }
        let entries = Int(number(tail, end + 10, 2))
        guard entries <= 4_096 else { throw ImportError("The ZIP exceeds the 4096 entry limit.") }
        guard number(tail, end + 4, 2) == 0, number(tail, end + 6, 2) == 0,
              number(tail, end + 8, 2) == UInt64(entries) else { throw ImportError("Multipart ZIP archives are unsupported.") }
        let directorySize = number(tail, end + 12, 4)
        var offset = number(tail, end + 16, 4)
        let endOffset = size - UInt64(tailSize) + UInt64(end)
        guard directorySize != 0xffff_ffff, offset != 0xffff_ffff,
              offset <= endOffset, directorySize == endOffset - offset else { throw ImportError("ZIP64 or corrupt ZIP directories are unsupported.") }
        var records: [Record] = []
        for _ in 0..<entries {
            let header = try bytes(at: offset, count: 46)
            guard number(header, 0, 4) == 0x02014b50 else { throw ImportError("The ZIP directory is corrupt.") }
            let flags = number(header, 8, 2)
            let method = number(header, 10, 2)
            guard flags & 0x41 == 0 else { throw ImportError("Encrypted ZIP archives are unsupported.") }
            guard method == 0 || method == 8 else { throw ImportError("The ZIP compression method is unsupported.") }
            let compressed = number(header, 20, 4)
            let inflated = number(header, 24, 4)
            let localOffset = number(header, 42, 4)
            guard compressed != 0xffff_ffff, inflated != 0xffff_ffff, localOffset != 0xffff_ffff,
                  number(header, 34, 2) == 0 else { throw ImportError("ZIP64 or multipart ZIP entries are unsupported.") }
            let local = try bytes(at: localOffset, count: 30)
            guard number(local, 0, 4) == 0x04034b50, number(local, 6, 2) == flags,
                  number(local, 8, 2) == method else { throw ImportError("The ZIP entry headers disagree.") }
            let centralName = try bytes(at: offset + 46, count: Int(number(header, 28, 2)))
            let localName = try bytes(at: localOffset + 30, count: Int(number(local, 26, 2)))
            guard centralName == localName else { throw ImportError("The ZIP entry filenames disagree.") }
            let payload = localOffset + 30 + number(local, 26, 2) + number(local, 28, 2)
            guard payload <= endOffset - directorySize, compressed <= endOffset - directorySize - payload else {
                throw ImportError("The ZIP entry data is truncated.")
            }
            if flags & 8 == 0 {
                guard number(local, 14, 4) == number(header, 16, 4),
                      number(local, 18, 4) == compressed, number(local, 22, 4) == inflated else {
                    throw ImportError("The ZIP entry headers disagree.")
                }
            }
            records.append(Record(size: inflated, compressed: compressed, crc: UInt32(number(header, 16, 4))))
            offset += 46 + number(header, 28, 2) + number(header, 30, 2) + number(header, 32, 2)
            guard offset <= endOffset else { throw ImportError("The ZIP directory is truncated.") }
        }
        guard offset == endOffset else { throw ImportError("The ZIP entry count is corrupt.") }
        return records
    }

    private static func number(_ data: Data, _ offset: Int, _ count: Int, bigEndian: Bool = false) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count {
            let shift = (bigEndian ? count - 1 - index : index) * 8
            value |= UInt64(data[offset + index]) << shift
        }
        return value
    }

    private static func validateCDG(_ data: Data) throws {
        let completeBytes = data.count - data.count % 24
        var found = false
        for offset in stride(from: 0, to: completeBytes, by: 24) where data[offset] & 0x3f == 9 {
            let instruction = data[offset + 1] & 0x3f
            let payload = offset + 4
            switch instruction {
            case 1, 2, 28, 30, 31: found = true
            case 6, 38:
                guard data[payload + 2] & 0x1f < 18, data[payload + 3] & 0x3f < 50 else {
                    continue
                }
                found = true
            case 20, 24:
                guard data[payload + 1] & 7 < 6, data[payload + 2] & 15 < 12,
                      (data[payload + 1] >> 4) & 3 < 3, (data[payload + 2] >> 4) & 3 < 3 else {
                    continue
                }
                found = true
            default: break // Audio/subcode padding and unknown instructions do not draw graphics.
            }
        }
        guard found else { throw ImportError("The CDG contains no complete valid graphics instruction.") }
    }

    private struct Tags { var title: String?; var artist: String?; var year: Int? }

    private static func clean(_ text: String) -> String? {
        let value = text.components(separatedBy: "\0").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func year(_ text: String?) -> Int? {
        guard let text, text.count >= 4 else { return nil }
        let prefix = text.prefix(4)
        guard prefix.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(prefix), value > 0 else { return nil }
        return value
    }

    private static func metadata(_ data: Data) -> Tags {
        var tags = Tags()
        if data.count >= 10, data.prefix(3) == Data("ID3".utf8), (3...4).contains(data[3]),
           data[5] & 0x80 == 0, (6..<10).allSatisfy({ data[$0] < 128 }) {
            let version = data[3]
            let size = (6..<10).reduce(0) { ($0 << 7) | Int(data[$1]) }
            // Display metadata has its own small bound; malformed tags never affect audio import.
            if size <= 1_024 * 1_024, size <= data.count - 10 {
                let end = 10 + size
                var offset = 10
                if data[5] & 0x40 != 0, end - offset >= 4 {
                    let extended = version == 4 ? syncSafe(data, offset) : Int(number(data, offset, 4, bigEndian: true))
                    offset += version == 4 ? extended : extended + 4
                    if extended < 4 { offset = end }
                }
                while offset >= 10, offset <= end - 10 {
                    let name = String(data: data.subdata(in: offset..<offset + 4), encoding: .ascii) ?? ""
                    let length = version == 4 ? syncSafe(data, offset + 4) : Int(number(data, offset + 4, 4, bigEndian: true))
                    guard length > 0, length <= end - offset - 10 else { break }
                    let flags = data[offset + 9]
                    if flags == 0, ["TIT2", "TPE1", "TDRC", "TYER"].contains(name) {
                        let text = decodeText(data.subdata(in: offset + 10..<offset + 10 + length))
                        switch name {
                        case "TIT2": tags.title = tags.title ?? text
                        case "TPE1": tags.artist = tags.artist ?? text
                        default: tags.year = tags.year ?? year(text)
                        }
                    }
                    offset += 10 + length
                }
            }
        }
        if data.count >= 128 {
            let start = data.count - 128
            if data.subdata(in: start..<start + 3) == Data("TAG".utf8) {
                func field(_ offset: Int, _ length: Int) -> String? {
                    clean(String(data: data.subdata(in: start + offset..<start + offset + length), encoding: .isoLatin1) ?? "")
                }
                tags.title = tags.title ?? field(3, 30)
                tags.artist = tags.artist ?? field(33, 30)
                tags.year = tags.year ?? year(field(93, 4))
            }
        }
        return tags
    }

    private static func syncSafe(_ data: Data, _ offset: Int) -> Int {
        guard (offset..<offset + 4).allSatisfy({ data[$0] < 128 }) else { return -1 }
        return (offset..<offset + 4).reduce(0) { ($0 << 7) | Int(data[$1]) }
    }

    private static func decodeText(_ data: Data) -> String? {
        guard let encoding = data.first, data.count > 1 else { return nil }
        let body = data.subdata(in: 1..<data.count)
        let stringEncoding: String.Encoding
        switch encoding {
        case 0: stringEncoding = .isoLatin1
        case 1: stringEncoding = .utf16
        case 2: stringEncoding = .utf16BigEndian
        case 3: stringEncoding = .utf8
        default: return nil
        }
        guard let text = String(data: body, encoding: stringEncoding) else { return nil }
        return clean(text)
    }
}
