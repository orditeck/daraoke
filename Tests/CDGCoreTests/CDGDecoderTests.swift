import Foundation
import Testing
@testable import CDGCore

struct CDGDecoderTests {
    private let colors: [UInt16] = [
        0x000, 0xF00, 0x0F0, 0x00F, 0xFF0, 0xF0F, 0x0FF, 0x777,
        0xFFF, 0xF80, 0x123, 0x456, 0x789, 0xABC, 0xDEF, 0x135
    ]

    private func packet(_ instruction: UInt8, _ payload: [UInt8] = [], command: UInt8 = 9, noisy: Bool = false) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 24)
        result[0] = command
        result[1] = instruction
        for (index, byte) in payload.prefix(16).enumerated() {
            result[index + 4] = byte
        }
        if noisy {
            for index in result.indices { result[index] |= 0xC0 }
        }
        return result
    }

    private func palette(_ first: Int, values: [UInt16]? = nil, noisy: Bool = false) -> [UInt8] {
        let values = values ?? Array(colors[first..<(first + 8)])
        var payload: [UInt8] = []
        for color in values {
            payload.append(UInt8((color >> 6) & 0x3F))
            payload.append(UInt8(color & 0x3F))
        }
        return packet(first == 0 ? 30 : 31, payload, noisy: noisy)
    }

    private func tile(row: UInt8 = 1, column: UInt8 = 1, zero: UInt8, one: UInt8? = nil, bits: UInt8 = 0, xor: Bool = false) -> [UInt8] {
        packet(xor ? 38 : 6, [zero, one ?? zero, row, column] + [UInt8](repeating: bits, count: 12))
    }

    private func decoder(_ packets: [[UInt8]], trailing: [UInt8] = []) -> CDGDecoder {
        CDGDecoder(data: Data(packets.flatMap { $0 } + trailing))
    }

    private func advance(_ decoder: CDGDecoder, toPacket count: Int) {
        decoder.seek(to: (Double(count) + 0.125) / 300)
    }

    private func pixel(_ decoder: CDGDecoder, x: Int = 0, y: Int = 0) -> [UInt8] {
        decoder.withRGBAFrame { bytes in
            let index = (y * 288 + x) * 4
            return Array(bytes[index..<(index + 4)])
        }
    }

    private func rgba(_ index: Int, alpha: UInt8 = 255) -> [UInt8] {
        let color = colors[index]
        return [UInt8((color >> 8) & 15) * 17, UInt8((color >> 4) & 15) * 17, UInt8(color & 15) * 17, alpha]
    }

    @Test
    func testPacketTimingLowerSixBitsAndTileBitOrder() {
        let cdg = decoder([
            palette(0, noisy: true),
            packet(1, [1], noisy: true),
            packet(6, [2, 3, 1, 1] + [UInt8](repeating: 0x20, count: 12), noisy: true)
        ])
        #expect(cdg.withRGBAFrame { $0.count } == 288 * 192 * 4)
        #expect(pixel(cdg) == [0, 0, 0, 255])
        let initialRevision = cdg.revision
        cdg.seek(to: 0.999 / 300)
        #expect(cdg.revision == initialRevision)
        cdg.seek(to: 1.001 / 300)
        #expect(pixel(cdg) == rgba(0))
        cdg.seek(to: 1.999 / 300)
        #expect(pixel(cdg) == rgba(0))
        cdg.seek(to: 2.001 / 300)
        #expect(pixel(cdg) == rgba(1))
        cdg.seek(to: 3.001 / 300)
        #expect(pixel(cdg) == rgba(3))
        #expect(pixel(cdg, x: 1) == rgba(2))
        #expect(pixel(cdg, x: 5, y: 11) == rgba(2))
        #expect(pixel(cdg, x: 6) == rgba(1))
        #expect(pixel(cdg, y: 12) == rgba(1))
    }

    @Test
    func testBothPaletteHalvesAndPaletteAnimation() {
        var changed = Array(colors[8..<16])
        changed[7] = 0x246
        let cdg = decoder([
            palette(0), palette(8, noisy: true), packet(1, [8]),
            tile(zero: 15), palette(8, values: changed), tile(column: 2, zero: 7)
        ])
        advance(cdg, toPacket: 3)
        #expect(pixel(cdg) == rgba(8))
        advance(cdg, toPacket: 4)
        #expect(pixel(cdg) == rgba(15))
        #expect(pixel(cdg, x: 6) == rgba(8))
        advance(cdg, toPacket: 5)
        #expect(pixel(cdg) == [34, 68, 102, 255])
        advance(cdg, toPacket: 6)
        #expect(pixel(cdg, x: 6) == rgba(7))
        #expect(pixel(cdg) == [34, 68, 102, 255])
    }

    @Test
    func testXORCombinesColorIndicesNotRGBAndCanUndoItself() {
        let xor = tile(zero: 2, one: 4, bits: 0x20, xor: true)
        let cdg = decoder([palette(0), packet(1, [1]), xor, xor])
        advance(cdg, toPacket: 3)
        #expect(pixel(cdg) == rgba(5))
        #expect(pixel(cdg, x: 1) == rgba(3))
        advance(cdg, toPacket: 4)
        #expect(pixel(cdg) == rgba(1))
        #expect(pixel(cdg, x: 1) == rgba(1))
    }

    @Test
    func testBorderIsHiddenUntilFineOffsetsExposeIt() {
        let cdg = decoder([
            palette(0), packet(1, [1]), packet(2, [2]),
            packet(24, [0, 5, 11]), packet(2, [3]),
            packet(24, [0, 0, 0])
        ])
        advance(cdg, toPacket: 3)
        #expect(pixel(cdg) == rgba(1))
        #expect(pixel(cdg, x: 287, y: 191) == rgba(1))
        advance(cdg, toPacket: 4)
        #expect(pixel(cdg, x: 282, y: 180) == rgba(1))
        #expect(pixel(cdg, x: 283) == rgba(2))
        #expect(pixel(cdg, y: 181) == rgba(2))
        advance(cdg, toPacket: 5)
        #expect(pixel(cdg, x: 283) == rgba(3))
        #expect(pixel(cdg, y: 181) == rgba(3))
        advance(cdg, toPacket: 6)
        #expect(pixel(cdg, x: 287, y: 191) == rgba(1))
    }

    @Test
    func testScrollCopyMovesAndWrapsInAllFourDirections() {
        let base = [
            palette(0), packet(1, [0]), tile(zero: 1),
            tile(column: 0, zero: 2), tile(column: 49, zero: 3),
            tile(row: 0, zero: 4), tile(row: 17, zero: 5)
        ]
        let right = decoder(base + [packet(24, [0, 0x10, 0]), packet(24, [0, 0x10, 0])])
        advance(right, toPacket: base.count + 1)
        #expect(pixel(right) == rgba(2))
        #expect(pixel(right, x: 6) == rgba(1))
        advance(right, toPacket: base.count + 2)
        #expect(pixel(right) == rgba(3), "Right edge must wrap back to the left")

        let left = decoder(base + [packet(24, [0, 0x20, 0]), packet(24, [0, 0x20, 0])])
        advance(left, toPacket: base.count + 1)
        #expect(pixel(left, x: 282) == rgba(3))
        advance(left, toPacket: base.count + 2)
        #expect(pixel(left, x: 282) == rgba(2), "Left edge must wrap back to the right")

        let down = decoder(base + [packet(24, [0, 0, 0x10]), packet(24, [0, 0, 0x10])])
        advance(down, toPacket: base.count + 1)
        #expect(pixel(down) == rgba(4))
        #expect(pixel(down, y: 12) == rgba(1))
        advance(down, toPacket: base.count + 2)
        #expect(pixel(down) == rgba(5), "Bottom edge must wrap back to the top")

        let up = decoder(base + [packet(24, [0, 0, 0x20]), packet(24, [0, 0, 0x20])])
        advance(up, toPacket: base.count + 1)
        #expect(pixel(up, y: 180) == rgba(5))
        advance(up, toPacket: base.count + 2)
        #expect(pixel(up, y: 180) == rgba(4), "Top edge must wrap back to the bottom")
    }

    @Test
    func testScrollPresetFillsInsteadOfWrappingInAllFourDirections() {
        let cases: [(UInt8, UInt8, Int, Int)] = [
            (0x10, 0, 0, 0), (0x20, 0, 282, 0),
            (0, 0x10, 0, 0), (0, 0x20, 0, 180)
        ]
        for (horizontal, vertical, x, y) in cases {
            let cdg = decoder([
                palette(0), packet(1, [1]),
                packet(20, [2, horizontal, vertical]), packet(20, [2, horizontal, vertical])
            ])
            advance(cdg, toPacket: 4)
            #expect(pixel(cdg, x: x, y: y) == rgba(2))
            #expect(pixel(cdg, x: 100, y: 100) == rgba(1))
        }
    }

    @Test
    func testSimultaneousHorizontalAndVerticalScroll() {
        let cdg = decoder([
            palette(0), tile(zero: 1),
            packet(24, [0, 0x10, 0x10]), packet(24, [0, 0x20, 0x20])
        ])
        advance(cdg, toPacket: 3)
        #expect(pixel(cdg) == rgba(0))
        #expect(pixel(cdg, x: 6, y: 12) == rgba(1))
        advance(cdg, toPacket: 4)
        #expect(pixel(cdg) == rgba(1))
        #expect(pixel(cdg, x: 6, y: 12) == rgba(0))
    }

    @Test
    func testTransparencyChangesIndexAndSurvivesPaletteReload() {
        var changed = Array(colors[0..<8])
        changed[2] = 0x00F
        let cdg = decoder([
            palette(0), packet(1, [1]), packet(28, [1]),
            packet(28, [2]), tile(zero: 2), palette(0, values: changed)
        ])
        advance(cdg, toPacket: 3)
        #expect(pixel(cdg) == rgba(1, alpha: 0))
        advance(cdg, toPacket: 4)
        #expect(pixel(cdg) == rgba(1))
        advance(cdg, toPacket: 5)
        #expect(pixel(cdg) == rgba(2, alpha: 0))
        advance(cdg, toPacket: 6)
        #expect(pixel(cdg) == [0, 0, 255, 0])
        cdg.reset()
        #expect(pixel(cdg) == [0, 0, 0, 255])
    }

    @Test
    func testBackwardSeekAndResetReplayDeterministically() {
        let packets = [
            palette(0), palette(8), packet(1, [9]), tile(zero: 15),
            packet(24, [0, 0x15, 0x1B]), packet(28, [9]),
            tile(row: 4, column: 5, zero: 3, xor: true)
        ]
        let cdg = decoder(packets)
        advance(cdg, toPacket: packets.count)
        let expected = cdg.withRGBAFrame { Array($0) }
        let finalRevision = cdg.revision
        advance(cdg, toPacket: 4)
        #expect(cdg.revision > finalRevision)
        #expect(pixel(cdg) == rgba(15))
        advance(cdg, toPacket: packets.count)
        #expect(cdg.withRGBAFrame { Array($0) } == expected)
        cdg.reset()
        #expect(pixel(cdg) == rgba(0))
        advance(cdg, toPacket: packets.count)
        #expect(cdg.withRGBAFrame { Array($0) } == expected)
    }

    @Test
    func testRevisionAndCachedFrameAreStableWithoutGraphicsChanges() {
        let packets = [
            palette(0), packet(1, [1]),
            packet(1, [1]), packet(1, [2, 1]), packet(63, [3]),
            packet(1, [3], command: 8), tile(zero: 0, xor: true),
            packet(24), palette(0), tile(zero: 1)
        ]
        let cdg = decoder(packets)
        advance(cdg, toPacket: 2)
        let revision = cdg.revision
        let expected = cdg.withRGBAFrame { Array($0) }
        advance(cdg, toPacket: packets.count)
        #expect(cdg.revision == revision)
        #expect(cdg.withRGBAFrame { Array($0) } == expected)
        advance(cdg, toPacket: packets.count)
        #expect(cdg.revision == revision)
        cdg.reset()
        #expect(cdg.revision > revision)
    }

    @Test
    func testDirtyTilesUpdateAtFineOffsetsAndPreserveCachedPixels() {
        let cdg = decoder([
            palette(0), packet(1, [1]), packet(24, [0, 3, 5]),
            tile(row: 2, column: 2, zero: 2), tile(row: 3, column: 3, zero: 3)
        ])
        advance(cdg, toPacket: 3)
        #expect(pixel(cdg, x: 3, y: 7) == rgba(1))
        let revision = cdg.revision
        advance(cdg, toPacket: 4)
        #expect(cdg.revision > revision)
        #expect(pixel(cdg, x: 3, y: 7) == rgba(2))
        #expect(pixel(cdg, x: 2, y: 7) == rgba(1))
        #expect(pixel(cdg, x: 3, y: 6) == rgba(1))
        advance(cdg, toPacket: 5)
        #expect(pixel(cdg, x: 3, y: 7) == rgba(2))
        #expect(pixel(cdg, x: 9, y: 19) == rgba(3))
        #expect(pixel(cdg, x: 100, y: 100) == rgba(1))
    }

    @Test
    func testMalformedCoordinatesOffsetsAndTrailingPacketAreSafe() {
        let partial = Array(packet(1, [3]).prefix(23))
        let cdg = decoder([
            palette(0), packet(1, [1]), tile(row: 31, column: 63, zero: 2),
            packet(24, [0, 7, 15]), packet(24, [0, 0x35, 0x3B])
        ], trailing: partial)
        advance(cdg, toPacket: 3)
        #expect(pixel(cdg, x: 287, y: 191) == rgba(1))
        advance(cdg, toPacket: 4)
        #expect(pixel(cdg, x: 287, y: 191) == rgba(2))
        let revision = cdg.revision
        cdg.seek(to: Double.greatestFiniteMagnitude)
        #expect(cdg.revision == revision, "Reserved scroll directions must not move pixels")
        #expect(pixel(cdg) == rgba(1))
        #expect(pixel(cdg, x: 287, y: 191) == rgba(2), "Partial trailing packet must be ignored")
    }

    @Test
    func testEmptyAndPartialInputAndInvalidTimeClampToZero() {
        for data in [Data(), Data([9]), Data(packet(1, [1]).prefix(23))] {
            let cdg = CDGDecoder(data: data)
            cdg.seek(to: Double.greatestFiniteMagnitude)
            #expect(pixel(cdg) == [0, 0, 0, 255])
        }
        for invalid in [-1.0, -Double.infinity, Double.infinity, Double.nan] {
            let cdg = decoder([palette(0), packet(1, [1])])
            advance(cdg, toPacket: 2)
            #expect(pixel(cdg) == rgba(1))
            cdg.seek(to: invalid)
            #expect(pixel(cdg) == [0, 0, 0, 255])
        }
    }

    @Test
    func testFrameClosurePropagatesErrors() {
        enum Expected: Error { case failure }
        let cdg = decoder([])
        #expect(throws: Expected.self) {
            try cdg.withRGBAFrame { _ -> Void in throw Expected.failure }
        }
        #expect(pixel(cdg) == [0, 0, 0, 255])
    }
}
