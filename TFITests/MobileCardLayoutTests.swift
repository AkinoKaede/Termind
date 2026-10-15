import SwiftUI
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileCardLayoutTests {
    @Test(arguments: [20.0, 74.0, 120.0], [320.0, 600.0])
    func bothCardSurfacesBalanceExtraHeight(contentHeight: CGFloat, width: CGFloat) async throws {
        let content = Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1).frame(height: contentHeight)
        let cards = [
            AnyView(MobileCard { content }),
            AnyView(MobileActionCard(action: {}, content: { content }, actions: { EmptyView() })),
        ]
        for card in cards {
            let image = try await render(card, width: width)
            let bytes = try pixels(image)
            let rows = (0..<image.height).filter { y in
                let offset = (y * image.width + image.width / 2) * 4
                return bytes[offset] > 230 && bytes[offset + 1] < 25 && bytes[offset + 2] < 25
            }
            let first = try #require(rows.first)
            let last = try #require(rows.last)
            let topInset = CGFloat(first) / 2
            let bottomInset = CGFloat(image.height - last - 1) / 2
            #expect(abs(topInset - bottomInset) <= 0.5)
            #expect(topInset >= 16 && bottomInset >= 16)
            // Glass antialiasing can soften one device pixel at either content edge.
            #expect(abs(CGFloat(rows.count) / 2 - contentHeight) <= 1)
            #expect(CGFloat(image.height) / 2 == max(MobileCardLayout.minimumHeight, contentHeight + 32))
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [320.0, 600.0])
    func tagCountKeepsHostContentAlignedIncludingLargeText(language: String, width: CGFloat) async throws {
        for typeSize in [DynamicTypeSize.large, .xxxLarge, .accessibility3] {
            for scheme in [ColorScheme.light, .dark] {
                var images: [CGImage] = []
                for tagCount in 0...2 {
                    images.append(
                        try await render(
                            card(tagCount: tagCount)
                                .environment(\.locale, Locale(identifier: language))
                                .environment(\.dynamicTypeSize, typeSize)
                                .environment(\.colorScheme, scheme),
                            width: width
                        )
                    )
                }
                let reference = try #require(images.last)
                let header = CGRect(x: 0, y: 0, width: width, height: 58)
                let timestamp = CGRect(
                    x: width - 75, y: 58, width: 75, height: CGFloat(reference.height) / 2 - 58)
                let expectedHeader = try pixels(reference, in: header)
                let expectedTimestamp = try pixels(reference, in: timestamp)
                for image in images.dropLast() {
                    #expect(image.width == reference.width && image.height == reference.height)
                    let headerMatches = try pixels(image, in: header) == expectedHeader
                    let timestampMatches = try pixels(image, in: timestamp) == expectedTimestamp
                    #expect(headerMatches, "Removing tags must not move the host header.")
                    #expect(timestampMatches, "Removing tags must not move the timestamp.")
                }
            }
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [320.0, 600.0])
    func snippetFolderDoesNotMoveTheHeader(language: String, width: CGFloat) async throws {
        let snippet = Snippet(title: "Production database maintenance", body: "sudo systemctl restart postgresql")
        let date = Date().addingTimeInterval(-86_400)
        var images: [CGImage] = []
        for path in [nil, "Operations / Production / Database"] {
            images.append(
                try await render(
                    MobileActionCard(
                        action: {},
                        content: {
                            SnippetCardContent(
                                snippet: snippet, validTargetCount: 12, packagePath: path, modifiedAt: date)
                        }, actions: { EmptyView() }
                    )
                    .environment(\.locale, Locale(identifier: language)),
                    width: width))
        }
        let empty = try #require(images.first)
        let folder = try #require(images.last)
        #expect(empty.height == folder.height)
        let header = CGRect(x: 0, y: 0, width: width, height: 58)
        let emptyHeader = try pixels(empty, in: header)
        let folderHeader = try pixels(folder, in: header)
        let headersMatch = emptyHeader == folderHeader
        #expect(headersMatch)
        if !headersMatch {
            for (index, image) in images.enumerated() {
                let png = try #require(UIImage(cgImage: image, scale: 2, orientation: .up).pngData())
                Attachment.record(png, named: "snippet-folder-\(language)-\(Int(width))-\(index).png")
            }
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [320.0, 600.0])
    func exportHostCardReviewWhenRequested(language: String, width: CGFloat) async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_HOST_CARD_SCREENSHOTS"] == "1" else { return }
        for scheme in [ColorScheme.light, .dark] {
            let image = try await render(
                VStack(spacing: 16) {
                    ForEach(0...2, id: \.self) { count in
                        card(tagCount: count)
                    }
                }
                .padding(16)
                .background(Color(uiColor: .systemGroupedBackground))
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, scheme),
                width: width + 32
            )
            let data = try #require(UIImage(cgImage: image, scale: 2, orientation: .up).pngData())
            Attachment.record(data, named: "host-cards-ios-\(language)-\(Int(width))-\(scheme).png")
        }
    }

    private func card(tagCount: Int) -> some View {
        var host = TermindDomain.Host(name: "THome", host: "thome-router.internal.endpoint.example.invalid")
        host.tags = Array(["router", "home"].prefix(tagCount))
        return MobileActionCard(
            action: {},
            content: {
                MobileHostCardContent(
                    host: host, address: host.host, status: nil,
                    lastConnectedAt: Date().addingTimeInterval(-4 * 24 * 60 * 60))
            },
            actions: { EmptyView() }
        )
    }

    func render(_ content: some View, width: CGFloat) async throws -> CGImage {
        let controller = UIHostingController(rootView: content.frame(width: width))
        controller.safeAreaRegions = []
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // Native glass requires a window. Keep this one offscreen and non-key so
        // default layout tests never take over presentation or keyboard focus.
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: CGPoint(x: -10_000, y: 0), size: size)
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            controller.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        return try #require(image.cgImage)
    }

    private func pixels(_ image: CGImage, in rect: CGRect? = nil) throws -> [UInt8] {
        let crop: CGImage
        if let rect {
            crop = try #require(image.cropping(to: rect.applying(CGAffineTransform(scaleX: 2, y: 2))))
        } else {
            crop = image
        }
        var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            )
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return bytes
    }
}
