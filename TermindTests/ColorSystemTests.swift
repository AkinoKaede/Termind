import AppKit
import SwiftUI
import Testing

@testable import Termind

@MainActor
@Suite
struct ColorSystemTests {
    @Test
    func neutralPaletteAdaptsBetweenAquaAndDarkAqua() throws {
        let providers: [() -> Color] = [
            { TermindColor.windowSurface },
            { TermindColor.contentSurface },
            { TermindColor.textSurface },
            { TermindColor.primaryForeground },
            { TermindColor.secondaryForeground },
            { TermindColor.separator },
        ]

        for provider in providers {
            let light = try resolved(provider(), appearance: .aqua)
            let dark = try resolved(provider(), appearance: .darkAqua)
            #expect(colorDistance(light, dark) > 0.04)
        }
    }

    @Test
    func primaryTextKeepsReadableContrastOnTheWindowSurface() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let foreground = try resolved(
                TermindColor.primaryForeground,
                appearance: appearance
            )
            let background = try resolved(
                TermindColor.windowSurface,
                appearance: appearance
            )
            #expect(contrastRatio(foreground, background) >= 4.5)
        }
    }

    @Test
    func markdownThemeIsConcreteForItsRequestedAppearance() throws {
        let lightValue = TermindMarkdownTheme.make(
            tone: .primary,
            colorScheme: .light
        )
        let darkValue = TermindMarkdownTheme.make(
            tone: .primary,
            colorScheme: .dark
        )
        let light = try #require(
            lightValue.theme.colors.body.usingColorSpace(.deviceRGB)
        )
        let dark = try #require(
            darkValue.theme.colors.body.usingColorSpace(.deviceRGB)
        )

        #expect(lightValue.colorScheme == .light)
        #expect(darkValue.colorScheme == .dark)
        #expect(colorDistance(light, dark) > 0.5)
    }

    @Test
    func featureUIHasNoLiteralDisplayColorsOrDecorativeBlue() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Termind", directoryHint: .isDirectory)
        let exemptPaths = [
            "Design/TerminalTheme.swift",
            "DesignSystem/TagColor+Presentation.swift",
        ]
        let forbidden = [
            "Color.white", "Color.black", "NSColor.white", "NSColor.gray",
            "foregroundStyle(.white)", "AnyShapeStyle(.white)",
            ".shadow(color: .black", "Color(white:", "Color(red:", "NSColor(red:",
            ".blue", "systemBlue",
        ]

        for file in try swiftFiles(in: sourceRoot) {
            let relative = file.path.replacingOccurrences(
                of: sourceRoot.path + "/",
                with: ""
            )
            if exemptPaths.contains(relative) { continue }
            let lines = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, line) in lines.enumerated() {
                // Black and white are alpha values here, not visible UI hues.
                let isMask =
                    relative == "Features/AI/TranscriptNativeRows.swift"
                    && line.contains("mask.colors")
                if isMask { continue }
                // A `TagColor` case a user picked for a host or key, not a hue
                // this code chose to draw. Its presentation is resolved through
                // the exempt `TagColor+Presentation.swift`, which is the file
                // this scan exists to funnel such choices into.
                if line.contains("colorTag:") { continue }
                for token in forbidden {
                    #expect(
                        !line.contains(token),
                        "\(relative):\(offset + 1) bypasses TermindColor with \(token)"
                    )
                }
            }
        }
    }

    @Test
    func nativeHostingListsReloadRowsWhenTheirEnvironmentChanges() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Termind", directoryHint: .isDirectory)

        for file in try swiftFiles(in: sourceRoot) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let environmentChangeCount =
                text.components(
                    separatedBy: "let environmentChanged"
                ).count - 1
            guard environmentChangeCount > 0 else { continue }
            let forcedReloadCount =
                text.components(
                    separatedBy: "if environmentChanged { listView.reloadData() }"
                ).count - 1
            #expect(
                forcedReloadCount == environmentChangeCount,
                "\(file.path) can leave recycled NSHostingView rows in the old appearance"
            )
        }
    }

    private func resolved(
        _ color: Color,
        appearance name: NSAppearance.Name
    ) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: name))
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.deviceRGB)
        }
        return try #require(result)
    }

    private func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let dr = lhs.redComponent - rhs.redComponent
        let dg = lhs.greenComponent - rhs.greenComponent
        let db = lhs.blueComponent - rhs.blueComponent
        return sqrt(dr * dr + dg * dg + db * db)
    }

    private func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let lighter = max(luminance(lhs), luminance(rhs))
        let darker = min(luminance(lhs), luminance(rhs))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent)
            + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private func swiftFiles(in root: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys)
            )
        else { return [] }
        return try enumerator.compactMap { value in
            guard let url = value as? URL, url.pathExtension == "swift" else { return nil }
            let values = try url.resourceValues(forKeys: keys)
            return values.isRegularFile == true ? url : nil
        }
    }
}
