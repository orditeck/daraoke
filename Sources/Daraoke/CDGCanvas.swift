import AppKit
import CDGCore
import SwiftUI

struct CDGCanvas: NSViewRepresentable {
    let decoder: CDGDecoder
    let revision: UInt64

    func makeNSView(context: Context) -> GraphicsView {
        let view = GraphicsView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Karaoke lyrics")
        return view
    }

    func updateNSView(_ view: GraphicsView, context: Context) {
        if view.decoder !== decoder || view.revision != revision {
            view.decoder = decoder
            view.revision = revision
            view.needsDisplay = true
        }
    }
}

final class GraphicsView: NSView {
    var decoder: CDGDecoder?
    var revision: UInt64 = 0

    override var isOpaque: Bool { true }

    // The stage owns pointer gestures; this view only renders lyrics.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let decoder, let context = NSGraphicsContext.current?.cgContext else { return }
        let size = CGSize(width: min(bounds.width, bounds.height * 4 / 3),
                          height: min(bounds.height, bounds.width * 3 / 4))
        let rect = CGRect(x: (bounds.width - size.width) / 2,
                          y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        // Both decode and draw run on the main actor. The provider cannot outlive
        // this closure, so Quartz reads the reusable buffer without a frame copy.
        decoder.withRGBAFrame { bytes in
            guard let address = bytes.baseAddress,
                  let provider = CGDataProvider(dataInfo: nil, data: address, size: bytes.count,
                                                releaseData: { _, _, _ in }),
                  let image = CGImage(width: CDGFormat.visibleWidth, height: CDGFormat.visibleHeight,
                                      bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: CDGFormat.visibleWidth * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent) else { return }
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(image, in: rect)
            context.restoreGState()
        }
    }
}
