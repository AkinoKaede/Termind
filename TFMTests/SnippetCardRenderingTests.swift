import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import TermindDomain
import TermindPresentation
import Testing
import UniformTypeIdentifiers

@Suite @MainActor
struct SnippetCardRenderingTests {
    @Test
    func exportCardReviewWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["TERMIND_SNIPPET_SCREENSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for locale in ["en", "zh-Hans", "zh-Hant"] {
            for scheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(
                    content: HStack(alignment: .top, spacing: 24) {
                        ForEach([CGFloat(216), 356], id: \.self) { width in
                            VStack(spacing: 16) {
                                ForEach(["uptime", "sudo systemctl restart nginx", "rm -rf /"], id: \.self) { script in
                                    card(script: script)
                                        .frame(width: width)
                                        .padding(12)
                                        .background(.quaternary, in: .rect(cornerRadius: 10))
                                }
                            }
                        }
                    }
                    .padding(24)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.locale, Locale(identifier: locale))
                    .environment(\.colorScheme, scheme)
                )
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                let url = URL(filePath: directory).appending(path: "snippets-\(locale)-\(scheme).png")
                let destination = try #require(
                    CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                #expect(CGImageDestinationFinalize(destination))
            }
        }
    }

    private func card(script: String) -> some View {
        SnippetCardContent(
            snippet: Snippet(title: "Production database maintenance / 生产数据库维护", body: script),
            validTargetCount: 12,
            packagePath: "Operations / Production / Database / 数据库维护",
            modifiedAt: Date().addingTimeInterval(-3600))
    }
}
