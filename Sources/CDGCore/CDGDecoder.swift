import Foundation

/// Stateful CD+G decoder. Use on one thread, and consume frame bytes only inside
/// `withRGBAFrame`; the same backing storage is reused for subsequent frames.
public final class CDGDecoder {
    public private(set) var revision: UInt64 = 0

    private let bytes: [UInt8]
    private let packetCount: Int
    private var nextPacket = 0
    private var pixels = [UInt8](repeating: 0, count: CDGFormat.width * CDGFormat.height)
    private var scratch = [UInt8](repeating: 0, count: CDGFormat.width * CDGFormat.height)
    private var palette = [UInt8](repeating: 0, count: 16 * 4)
    private var frame = [UInt8](repeating: 0, count: CDGFormat.visibleWidth * CDGFormat.visibleHeight * 4)
    private var transparentColor: UInt8?
    private var horizontalOffset = 0
    private var verticalOffset = 0
    private var dirtyMinX = CDGFormat.width
    private var dirtyMinY = CDGFormat.height
    private var dirtyMaxX = -1
    private var dirtyMaxY = -1

    public init(data: Data) {
        bytes = Array(data)
        packetCount = bytes.count / CDGFormat.packetSize
        reset()
    }

    /// Applies the complete packets elapsed at 300 packets per second. Invalid
    /// times mean zero; seeking backwards reconstructs the state from the start.
    public func seek(to seconds: Double) {
        let target: Int
        if seconds.isFinite && seconds > 0 {
            target = Int(min(seconds * Double(CDGFormat.packetsPerSecond), Double(packetCount)))
        } else {
            target = 0
        }
        if target < nextPacket {
            reset()
        }
        while nextPacket < target {
            decode(at: nextPacket * CDGFormat.packetSize)
            nextPacket += 1
        }
    }

    public func reset() {
        nextPacket = 0
        horizontalOffset = 0
        verticalOffset = 0
        transparentColor = nil
        for index in pixels.indices {
            pixels[index] = 0
        }
        for index in 0..<16 {
            let base = index * 4
            palette[base] = 0
            palette[base + 1] = 0
            palette[base + 2] = 0
            palette[base + 3] = 255
        }
        invalidateFrame()
    }

    public func withRGBAFrame<T>(_ body: (UnsafeBufferPointer<UInt8>) throws -> T) rethrows -> T {
        updateFrame()
        return try frame.withUnsafeBufferPointer(body)
    }

    private func decode(at packet: Int) {
        guard bytes[packet] & 0x3F == 9 else { return }
        let data = packet + 4
        switch bytes[packet + 1] & 0x3F {
        case 1:
            guard bytes[data + 1] & 0x0F == 0 else { return }
            let color = bytes[data] & 0x0F
            var changed = false
            for index in pixels.indices where pixels[index] != color {
                pixels[index] = color
                changed = true
            }
            if changed { invalidateFrame() }
        case 2:
            let color = bytes[data] & 0x0F
            var changed = false
            for y in 0..<CDGFormat.height {
                for x in 0..<CDGFormat.width where x < 6 || x >= 294 || y < 12 || y >= 204 {
                    let index = y * CDGFormat.width + x
                    if pixels[index] != color {
                        pixels[index] = color
                        changed = true
                    }
                }
            }
            if changed { invalidateFrame() }
        case 6, 38:
            tile(at: data, xor: bytes[packet + 1] & 0x3F == 38)
        case 20, 24:
            scroll(at: data, copy: bytes[packet + 1] & 0x3F == 24)
        case 28:
            let color = bytes[data] & 0x0F
            if transparentColor != color {
                if let previous = transparentColor {
                    palette[Int(previous) * 4 + 3] = 255
                }
                transparentColor = color
                palette[Int(color) * 4 + 3] = 0
                invalidateFrame()
            }
        case 30, 31:
            loadPalette(at: data, firstColor: bytes[packet + 1] & 0x3F == 30 ? 0 : 8)
        default:
            break
        }
    }

    private func tile(at data: Int, xor: Bool) {
        // Malformed tile positions are clamped to the last complete tile.
        let y = min(Int(bytes[data + 2] & 0x1F), 17) * 12
        let x = min(Int(bytes[data + 3] & 0x3F), 49) * 6
        let color0 = bytes[data] & 0x0F
        let color1 = bytes[data + 1] & 0x0F
        var changed = false
        for row in 0..<12 {
            let bits = bytes[data + 4 + row] & 0x3F
            for column in 0..<6 {
                let index = (y + row) * CDGFormat.width + x + column
                let color = bits & (0x20 >> column) == 0 ? color0 : color1
                let result = xor ? pixels[index] ^ color : color
                if pixels[index] != result {
                    pixels[index] = result
                    changed = true
                }
            }
        }
        if changed {
            markDirty(minX: x, minY: y, maxX: x + 5, maxY: y + 11)
            revision &+= 1
        }
    }

    private func scroll(at data: Int, copy: Bool) {
        let horizontal = bytes[data + 1] & 0x3F
        let vertical = bytes[data + 2] & 0x3F
        let offsetX = min(Int(horizontal & 0x07), 5)
        let offsetY = min(Int(vertical & 0x0F), 11)
        var changed = offsetX != horizontalOffset || offsetY != verticalOffset
        horizontalOffset = offsetX
        verticalOffset = offsetY
        let horizontalCommand = (horizontal >> 4) & 3
        let verticalCommand = (vertical >> 4) & 3
        let deltaX = horizontalCommand == 1 ? 6 : (horizontalCommand == 2 ? -6 : 0)
        let deltaY = verticalCommand == 1 ? 12 : (verticalCommand == 2 ? -12 : 0)
        if deltaX != 0 || deltaY != 0 {
            let color = bytes[data] & 0x0F
            for y in 0..<CDGFormat.height {
                let sourceY = y - deltaY
                let wrappedY = (sourceY + CDGFormat.height) % CDGFormat.height
                for x in 0..<CDGFormat.width {
                    let sourceX = x - deltaX
                    let result: UInt8
                    if copy {
                        let wrappedX = (sourceX + CDGFormat.width) % CDGFormat.width
                        result = pixels[wrappedY * CDGFormat.width + wrappedX]
                    } else if sourceX < 0 || sourceX >= CDGFormat.width || sourceY < 0 || sourceY >= CDGFormat.height {
                        result = color
                    } else {
                        result = pixels[sourceY * CDGFormat.width + sourceX]
                    }
                    let index = y * CDGFormat.width + x
                    scratch[index] = result
                    if result != pixels[index] { changed = true }
                }
            }
            // Both arrays stay uniquely owned: no full-screen COW snapshots.
            swap(&pixels, &scratch)
        }
        if changed { invalidateFrame() }
    }

    private func loadPalette(at data: Int, firstColor: Int) {
        var changed = false
        for index in 0..<8 {
            let high = bytes[data + index * 2] & 0x3F
            let low = bytes[data + index * 2 + 1] & 0x3F
            let base = (firstColor + index) * 4
            let red = ((high >> 2) & 0x0F) * 17
            let green = (((high & 3) << 2) | (low >> 4)) * 17
            let blue = (low & 0x0F) * 17
            if palette[base] != red || palette[base + 1] != green || palette[base + 2] != blue {
                palette[base] = red
                palette[base + 1] = green
                palette[base + 2] = blue
                changed = true
            }
        }
        if changed { invalidateFrame() }
    }

    private func invalidateFrame() {
        markDirty(minX: 0, minY: 0, maxX: CDGFormat.width - 1, maxY: CDGFormat.height - 1)
        revision &+= 1
    }

    private func markDirty(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        dirtyMinX = min(dirtyMinX, minX)
        dirtyMinY = min(dirtyMinY, minY)
        dirtyMaxX = max(dirtyMaxX, maxX)
        dirtyMaxY = max(dirtyMaxY, maxY)
    }

    private func updateFrame() {
        let originX = 6 + horizontalOffset
        let originY = 12 + verticalOffset
        let minX = max(dirtyMinX, originX)
        let minY = max(dirtyMinY, originY)
        let maxX = min(dirtyMaxX, originX + CDGFormat.visibleWidth - 1)
        let maxY = min(dirtyMaxY, originY + CDGFormat.visibleHeight - 1)
        if minX <= maxX && minY <= maxY {
            frame.withUnsafeMutableBufferPointer { destination in
                pixels.withUnsafeBufferPointer { source in
                    palette.withUnsafeBufferPointer { colors in
                        for y in minY...maxY {
                            for x in minX...maxX {
                                let color = Int(source[y * CDGFormat.width + x]) * 4
                                let output = ((y - originY) * CDGFormat.visibleWidth + x - originX) * 4
                                destination[output] = colors[color]
                                destination[output + 1] = colors[color + 1]
                                destination[output + 2] = colors[color + 2]
                                destination[output + 3] = colors[color + 3]
                            }
                        }
                    }
                }
            }
        }
        dirtyMinX = CDGFormat.width
        dirtyMinY = CDGFormat.height
        dirtyMaxX = -1
        dirtyMaxY = -1
    }
}
