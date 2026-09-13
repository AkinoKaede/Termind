import Foundation
import UIKit

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
            .font: UIFont.systemFont(ofSize: 16)
        ]
        let size = text.size(withAttributes: attributes)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: max(1, ceil(size.width)), height: max(1, ceil(size.height))),
            format: format
        )
        let image = renderer.image { _ in
            text.draw(at: .zero, withAttributes: attributes)
        }
        guard
            let data = image.cgImage?.dataProvider?.data,
            let bytes = CFDataGetBytePtr(data)
        else { return false }
        return containsColoredPixel(Array(UnsafeBufferPointer(start: bytes, count: CFDataGetLength(data))))
    }
}
