import Foundation
import SwiftUI

#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

/// Converts a Simple Icons brand hex into a foreground that remains legible on
/// the 16%-opacity tint surface used by host icons. Only luminance moves,
/// toward the current semantic label color, and only when the original brand
/// color misses 3:1.
@MainActor
public enum LinuxDistributionBrandColor {
    public static func color(hex: String, colorScheme: ColorScheme) -> Color? {
        guard let foreground = RGB(hex: hex) else { return nil }
        guard let semantic = semanticColors(for: colorScheme) else {
            return foreground.color
        }

        var candidate = foreground
        for step in 0...20 {
            let amount = CGFloat(step) / 20
            candidate = foreground.mixed(with: semantic.label, amount: amount)
            let tintedSurface = semantic.surface.mixed(with: candidate, amount: 0.16)
            if candidate.contrastRatio(with: tintedSurface) >= 3 {
                return candidate.color
            }
        }
        return candidate.color
    }

    private static func semanticColors(for colorScheme: ColorScheme) -> (surface: RGB, label: RGB)? {
        #if os(macOS)
            let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
            guard let appearance = NSAppearance(named: appearanceName) else { return nil }
            var surface: RGB?
            var label: RGB?
            appearance.performAsCurrentDrawingAppearance {
                surface = RGB(NSColor.controlBackgroundColor)
                label = RGB(NSColor.labelColor)
            }
        #elseif canImport(UIKit)
            let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
            let surface = RGB(UIColor.secondarySystemGroupedBackground.resolvedColor(with: traits))
            let label = RGB(UIColor.label.resolvedColor(with: traits))
        #else
            let surface: RGB? = nil
            let label: RGB? = nil
        #endif
        guard let surface, let label else { return nil }
        return (surface, label)
    }
}

private struct RGB {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    init?(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        red = CGFloat((value >> 16) & 0xFF) / 255
        green = CGFloat((value >> 8) & 0xFF) / 255
        blue = CGFloat(value & 0xFF) / 255
    }

    #if os(macOS)
        init?(_ color: NSColor) {
            guard let value = color.usingColorSpace(.deviceRGB) else { return nil }
            red = value.redComponent
            green = value.greenComponent
            blue = value.blueComponent
        }
    #elseif canImport(UIKit)
        init?(_ color: UIColor) {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            guard color.getRed(&red, green: &green, blue: &blue, alpha: nil) else { return nil }
            self.red = red
            self.green = green
            self.blue = blue
        }
    #endif

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    func mixed(with other: Self, amount: CGFloat) -> Self {
        Self(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }

    func contrastRatio(with other: Self) -> CGFloat {
        let lighter = max(luminance, other.luminance)
        let darker = min(luminance, other.luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private var luminance: CGFloat {
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}
