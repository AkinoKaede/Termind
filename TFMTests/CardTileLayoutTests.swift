import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct CardTileLayoutTests {
    @Test(arguments: [20.0, 56.0, 100.0], [240.0, 380.0])
    func minimumHeightKeepsContentCenteredWithoutClipping(contentHeight: CGFloat, width: CGFloat) throws {
        let image = try render(
            CardTile {
                Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
                    .frame(height: contentHeight)
            }
            .frame(width: width)
        )
        let bitmap = NSBitmapImageRep(cgImage: image)
        let contentRows = (0..<bitmap.pixelsHigh).filter { y in
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB) else {
                return false
            }
            return color.redComponent > 0.9 && color.greenComponent < 0.1 && color.blueComponent < 0.1
        }
        let firstRow = try #require(contentRows.first)
        let lastRow = try #require(contentRows.last)
        let topInset = CGFloat(firstRow) / 2
        let bottomInset = CGFloat(bitmap.pixelsHigh - lastRow - 1) / 2

        #expect(abs(topInset - bottomInset) <= 0.5)
        #expect(topInset >= Metrics.Space.l && bottomInset >= Metrics.Space.l)
        #expect(CGFloat(contentRows.count) / 2 == contentHeight)
        #expect(CGFloat(image.width) / 2 == width)
        #expect(CGFloat(image.height) / 2 == max(Metrics.Card.minHeight, contentHeight + 2 * Metrics.Space.l))
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [240.0, 380.0])
    func tagCountDoesNotMoveTheHeaderOrTimestamp(language: String, width: CGFloat) throws {
        for connected in [false, true] {
            let fixture = HostCardFixture(connected: connected)
            defer { fixture.app.shutdownForTermination() }
            for scheme in [ColorScheme.light, .dark] {
                let images = try (0...2).map { tagCount in
                    try render(
                        fixture.card(tagCount: tagCount)
                            .frame(width: width)
                            .environment(\.locale, Locale(identifier: language))
                            .environment(\.colorScheme, scheme)
                    )
                }
                let reference = try #require(images.last)
                let headerHeight = Metrics.Space.l + Metrics.Card.icon + Metrics.Space.xs
                let header = CGRect(x: 0, y: 0, width: width, height: headerHeight)
                let timestamp = CGRect(
                    x: width - 90, y: headerHeight, width: 90,
                    height: CGFloat(reference.height) / 2 - headerHeight)
                let expectedHeader = try pixels(reference, in: header)
                let expectedTimestamp = try pixels(reference, in: timestamp)

                // Compare actual rendering across different tag counts, including text baselines.
                for image in images.dropLast() {
                    #expect(image.width == reference.width && image.height == reference.height)
                    let headerMatches = try pixels(image, in: header) == expectedHeader
                    let timestampMatches = try pixels(image, in: timestamp) == expectedTimestamp
                    #expect(headerMatches, "The icon, name and address must not move when tags are removed.")
                    #expect(timestampMatches, "The timestamp must not move when tags are removed.")
                }
            }
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [240.0, 380.0])
    func snippetFolderDoesNotMoveTheHeader(language: String, width: CGFloat) throws {
        let snippet = Snippet(title: "Production database maintenance", body: "sudo systemctl restart postgresql")
        let date = Date().addingTimeInterval(-86_400)
        let images = try [nil, "Operations / Production / Database"].map { path in
            try render(
                CardTile {
                    SnippetCardContent(snippet: snippet, validTargetCount: 12, packagePath: path, modifiedAt: date)
                }
                .frame(width: width)
                .environment(\.locale, Locale(identifier: language)))
        }
        let empty = try #require(images.first)
        let folder = try #require(images.last)
        #expect(empty.height == folder.height)
        let header = CGRect(x: 0, y: 0, width: width, height: 44)
        let emptyHeader = try pixels(empty, in: header)
        let folderHeader = try pixels(folder, in: header)
        let headersMatch = emptyHeader == folderHeader
        #expect(headersMatch)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [240.0, 380.0])
    func exportHostCardReviewWhenRequested(language: String, width: CGFloat) throws {
        guard let directory = ProcessInfo.processInfo.environment["TERMIND_HOST_CARD_SCREENSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fixture = HostCardFixture(connected: true)
        defer { fixture.app.shutdownForTermination() }
        for scheme in [ColorScheme.light, .dark] {
            let image = try render(
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0...2, id: \.self) { tagCount in
                        fixture.card(tagCount: tagCount).frame(width: width)
                    }
                }
                .padding(24)
                .background(TermindColor.windowSurface)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, scheme)
            )
            let bitmap = NSBitmapImageRep(cgImage: image)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = "host-cards-\(language)-\(Int(width))-\(scheme).png"
            try data.write(to: URL(filePath: directory).appending(path: name))
            Attachment.record(data, named: name)
        }
    }

    private func render(_ content: some View) throws -> CGImage {
        // ImageRenderer omits native glass content; capture an offscreen hosting view instead.
        let view = NSHostingView(rootView: content)
        view.frame = CGRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        )
        bitmap.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.cgImage)
    }

    private func pixels(_ image: CGImage, in rect: CGRect) throws -> [UInt8] {
        let crop = try #require(image.cropping(to: rect.applying(CGAffineTransform(scaleX: 2, y: 2))))
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

@MainActor
private struct HostCardFixture {
    let host: TermindDomain.Host
    let app: AppModel
    let window = WindowModel()

    init(connected: Bool) {
        let host = TermindDomain.Host(name: "THome", host: "thome-router.internal.endpoint.example.invalid")
        self.host = host
        let history = ConnectionHistoryModel(
            entries: connected
                ? [
                    ConnectionHistoryEntry(
                        hostID: host.id, kind: .ssh, connectedAt: Date().addingTimeInterval(-4 * 24 * 60 * 60))
                ] : []
        )
        app = AppModel(hosts: HostLibraryModel(hosts: [host]), connectionHistory: history)
    }

    func card(tagCount: Int) -> some View {
        var host = host
        host.tags = Array(["router", "home"].prefix(tagCount))
        return HostCard(
            host: host, isSelected: false, select: {}, extendSelection: {},
            actionHosts: [host], requestDelete: {}
        )
        .environment(app)
        .environment(window)
    }
}
