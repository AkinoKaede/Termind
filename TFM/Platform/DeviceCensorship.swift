import AppKit
import Foundation

enum DeviceCensorship {
    static let canDisplayTaiwanFlag: Bool = detectTaiwanFlagColor()

    static func containsColoredPixel(_ bytes: [UInt8], bytesPerPixel: Int = 4) -> Bool {
        guard bytesPerPixel >= 3, bytes.count >= bytesPerPixel else { return false }
        return stride(from: 0, through: bytes.count - bytesPerPixel, by: bytesPerPixel).contains { offset in
            let red = bytes[offset]
            let green = bytes[offset + 1]
            let blue = bytes[offset + 2]
            return red != green || green != blue
        }
    }

    private static func detectTaiwanFlagColor() -> Bool {
        let text = "🇹🇼" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16)
        ]
        let size = text.size(withAttributes: attributes)
        let width = max(1, Int(ceil(size.width)))
        let height = max(1, Int(ceil(size.height)))
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4,
                bitsPerPixel: 32
            ),
            let data = bitmap.bitmapData
        else { return false }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return false }
        NSGraphicsContext.current = context
        text.draw(at: .zero, withAttributes: attributes)
        context.flushGraphics()

        return containsColoredPixel(
            Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
        )
    }
}
