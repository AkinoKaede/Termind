import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
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
}
