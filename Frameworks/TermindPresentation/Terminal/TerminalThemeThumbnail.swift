import GhosttyTheme
import SwiftUI
import TermindDomain

/// A small color illustration, not a second implementation of Ghostty's configuration renderer.
public struct TerminalThemeThumbnailPalette: Equatable, Sendable {
    public var background: TermindTerminalPalette.RGB
    public var foreground: TermindTerminalPalette.RGB
    public var selection: TermindTerminalPalette.RGB
    public var selectionForeground: TermindTerminalPalette.RGB
    public var cursor: TermindTerminalPalette.RGB
    public var ansi: [TermindTerminalPalette.RGB]

    public init(theme: GhosttyThemeDefinition, customText: String = "") {
        let fallback = theme.isDark ? TermindTerminalPalette.termindDark : .termindLight
        background = .init(hex: theme.background) ?? fallback.background
        foreground = .init(hex: theme.foreground) ?? fallback.foreground
        selection = theme.selectionBackground.flatMap(TermindTerminalPalette.RGB.init(hex:)) ?? fallback.selection
        selectionForeground = theme.selectionForeground.flatMap(TermindTerminalPalette.RGB.init(hex:)) ?? foreground
        cursor = theme.cursorColor.flatMap(TermindTerminalPalette.RGB.init(hex:)) ?? foreground
        ansi = (0..<16).map { theme.palette[$0].flatMap(TermindTerminalPalette.RGB.init(hex:)) ?? fallback.ansi[$0] }
        for entry in TerminalCustomConfiguration(customText).entries {
            if entry.key == "palette" {
                let parts = entry.value.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count == 2, let index = Int(parts[0]), ansi.indices.contains(index),
                    let color = TermindTerminalPalette.RGB(hex: parts[1])
                {
                    ansi[index] = color
                }
                continue
            }
            guard let color = TermindTerminalPalette.RGB(hex: entry.value) else { continue }
            switch entry.key {
            case "background": background = color
            case "foreground": foreground = color
            case "selection-background": selection = color
            case "selection-foreground": selectionForeground = color
            case "cursor-color": cursor = color
            default: break
            }
        }
    }
}

public struct TerminalThemeThumbnail: View {
    private let palette: TerminalThemeThumbnailPalette
    private let showsPalette: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(theme: GhosttyThemeDefinition, customText: String = "", showsPalette: Bool = false) {
        palette = TerminalThemeThumbnailPalette(theme: theme, customText: customText)
        self.showsPalette = showsPalette
    }

    public var body: some View {
        Canvas { context, size in
            let sx = size.width / 144
            let sy = size.height / 96
            func bar(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ color: Color) {
                let rect = CGRect(x: x * sx, y: y * sy, width: width * sx, height: height * sy)
                context.fill(Path(roundedRect: rect, cornerRadius: min(3 * sy, rect.height / 2)), with: .color(color))
            }
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.background.color))
            bar(12, 14, 116, 7, palette.foreground.color)
            bar(8, 28, 128, 17, palette.selection.color)
            bar(12, 33, 69, 7, palette.selectionForeground.color)
            bar(86, 33, 44, 7, palette.selectionForeground.color)
            bar(12, 54, 30, 7, palette.ansi[2].color)
            bar(47, 54, 33, 7, palette.foreground.color)
            bar(85, 54, 18, 7, palette.foreground.color)
            bar(109, 51, 5, 13, palette.cursor.color)
        }
        .aspectRatio(1.5, contentMode: .fit)
        .overlay {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { index in
                            Rectangle().fill(palette.ansi[index].color)
                        }
                    }
                    .frame(height: geometry.size.height / 12)
                    .offset(y: showsPalette || reduceMotion ? 0 : geometry.size.height / 12)
                    .opacity(showsPalette ? 1 : 0)
                }
            }
            .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1) }
        .animation(reduceMotion ? .easeInOut(duration: 0.1) : .easeInOut(duration: 0.18), value: showsPalette)
        .accessibilityHidden(true)
    }
}
