import AppKit
import Foundation
import SwiftUI
import TermindDomain
import TermindPresentation

typealias LinuxDistributionIconEntry = TermindPresentation.LinuxDistributionIconEntry
typealias LinuxDistributionIconCatalog = TermindPresentation.LinuxDistributionIconCatalog

/// Converts a Simple Icons brand hex into a foreground that remains legible on
/// CardIcon's 16%-opacity tint surface. Only luminance moves, toward the current
/// semantic label color, and only when the original brand color misses 3:1.
@MainActor
enum LinuxDistributionBrandColor {
    static func color(hex: String, colorScheme: ColorScheme) -> Color? {
        guard let original = nsColor(hex: hex) else { return nil }
        let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
        guard let appearance = NSAppearance(named: appearanceName) else {
            return Color(nsColor: original)
        }

        var surface = NSColor.controlBackgroundColor
        var target = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            surface = NSColor.controlBackgroundColor.usingColorSpace(.deviceRGB) ?? surface
            target = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? target
        }
        guard let foreground = original.usingColorSpace(.deviceRGB),
            let background = surface.usingColorSpace(.deviceRGB),
            let label = target.usingColorSpace(.deviceRGB)
        else { return Color(nsColor: original) }

        var candidate = foreground
        for step in 0...20 {
            let amount = CGFloat(step) / 20
            candidate = mixed(foreground, label, amount: amount)
            let tintedSurface = mixed(background, candidate, amount: 0.16)
            if contrastRatio(candidate, tintedSurface) >= 3 {
                return Color(nsColor: candidate)
            }
        }
        return Color(nsColor: candidate)
    }

    static func nsColor(hex: String) -> NSColor? {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func mixed(_ lhs: NSColor, _ rhs: NSColor, amount: CGFloat) -> NSColor {
        let left = components(lhs)
        let right = components(rhs)
        return NSColor(
            srgbRed: left.0 + (right.0 - left.0) * amount,
            green: left.1 + (right.1 - left.1) * amount,
            blue: left.2 + (right.2 - left.2) * amount,
            alpha: 1
        )
    }

    private static func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        let lighter = max(luminance(lhs), luminance(rhs))
        let darker = min(luminance(lhs), luminance(rhs))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        let value = components(color)
        return 0.2126 * linear(value.0)
            + 0.7152 * linear(value.1)
            + 0.0722 * linear(value.2)
    }

    private static func components(_ color: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return (red, green, blue)
    }
}
