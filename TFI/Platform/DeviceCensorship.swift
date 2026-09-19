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
        let width = max(1, Int(ceil(size.width)))
        let height = max(1, Int(ceil(size.height)))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard
            let context = CGContext(
                data: &bytes,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return false }

        UIGraphicsPushContext(context)
        text.draw(at: .zero, withAttributes: attributes)
        UIGraphicsPopContext()
        context.flush()
        return containsColoredPixel(bytes)
    }
}
