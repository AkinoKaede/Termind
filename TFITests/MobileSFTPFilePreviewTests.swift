import SwiftUI
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@MainActor
struct MobileSFTPFilePreviewTests {
    @Test(arguments: [ColorScheme.light, .dark], [RemoteFile.Kind.file, .directory])
    func previewCarriesAnOpaqueBackground(scheme: ColorScheme, kind: RemoteFile.Kind) throws {
        for width: CGFloat in [320, 600] {
            for language in ["en", "zh-Hans"] {
                let name = language == "en" ? "Deployment configuration" : "部署配置文件"
                let file = RemoteFile(
                    path: "/srv/\(name)", name: name, kind: kind, size: 2_048,
                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    permissions: 0o755, ownerUID: 1_000, ownerGID: 1_000)
                let renderer = ImageRenderer(
                    content: MobileSFTPFilePreview(file: file, width: width)
                        .environment(\.colorScheme, scheme)
                        .environment(\.locale, Locale(identifier: language)))
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                #expect(image.width == Int(width))

                // Sample empty padding, where a transparent lifted row used to expose the list below.
                for point in [CGPoint(x: width / 2, y: 3), CGPoint(x: 3, y: image.height / 2)] {
                    let rgba = try pixel(in: image, at: point)
                    #expect(rgba[3] == 255)
                    if scheme == .light {
                        #expect(rgba.prefix(3).allSatisfy { $0 > 240 })
                    } else {
                        #expect(rgba.prefix(3).allSatisfy { $0 < 40 })
                    }
                }

                if let directory = ProcessInfo.processInfo.environment["TERMIND_SFTP_PREVIEW_SCREENSHOTS"] {
                    let url = URL(filePath: directory)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let data = try #require(UIImage(cgImage: image).pngData())
                    try data.write(to: url.appending(path: "preview-\(language)-\(scheme)-\(kind)-\(Int(width)).png"))
                }
            }
        }
    }

    private func pixel(in image: CGImage, at point: CGPoint) throws -> [UInt8] {
        let cropped = try #require(image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))))
        var bytes = [UInt8](repeating: 0, count: 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}
