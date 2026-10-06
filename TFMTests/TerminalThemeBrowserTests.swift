import AppKit
import GhosttyTerminal
import SwiftUI
import TermindDomain
import TermindPresentation
import Testing

@Suite @MainActor
struct TerminalThemeBrowserTests {
    @Test(arguments: [false, true])
    func searchKeepsAppearanceAndCustomSelectionIndependent(isDark: Bool) {
        let options = TerminalThemeOptions(
            preferences: TerminalPreferences(darkCustomEnabled: true, lightCustomEnabled: true), isDark: isDark)
        let results = options.themes(matching: "  TERMIND  ")
        #expect(!results.isEmpty)
        #expect(results.allSatisfy { $0.isDark == isDark && $0.name.contains("Termind") })
        #expect(options.themes(matching: "no-such-theme-123456").isEmpty)
        #expect(options.isCustom)
        #expect(!options.isSelected(options.name))
    }

    @Test func unavailableSelectionRetainsItsNameAndResolvesOnlyThePreview() {
        let preferences = TerminalPreferences(darkTheme: "Missing Theme")
        let options = TerminalThemeOptions(preferences: preferences, isDark: true)
        #expect(!options.isAvailable)
        #expect(options.name == "Missing Theme")
        #expect(options.baseTheme == TermindTerminalThemeCatalog.defaultDark)
        #expect(!options.isSelected(options.baseTheme.name))
    }

    @Test func thumbnailUsesThemeColorsAndOrderedCustomOverrides() {
        let theme = TermindTerminalThemeCatalog.defaultDark
        let base = TerminalThemeThumbnailPalette(theme: theme)
        #expect(base.background.hex == theme.background.uppercased())
        #expect(base.ansi[2].hex == theme.palette[2]?.uppercased())
        let palette = TerminalThemeThumbnailPalette(
            theme: theme,
            customText: """
                background = #102030
                background = 405060
                foreground = #AABBCC
                cursor-color = 112233
                selection-background = 223344
                selection-foreground = 334455
                palette = 2=#FF0000
                palette = 2=#00FF00
                palette = 17=#FFFFFF
                palette = invalid
                """)
        #expect(palette.background.hex == "405060")
        #expect(palette.foreground.hex == "AABBCC")
        #expect(palette.cursor.hex == "112233")
        #expect(palette.selection.hex == "223344")
        #expect(palette.selectionForeground.hex == "334455")
        #expect(palette.ansi[2].hex == "00FF00")
        #expect(palette.ansi[1] == base.ansi[1])
        #expect(TerminalThemeThumbnailPalette(theme: theme, customText: "background = invalid") == base)
    }

    @Test(arguments: [false, true])
    func draftPreviewReusesControllerAndRetainsLastValidConfiguration(isDark: Bool) {
        let model = TerminalConfigurationPreviewModel()
        let controller = model.terminal.controller
        let name = TermindTerminalThemeCatalog.fallbackTheme(isDark: isDark).name
        #expect(model.update(themeName: name, text: "background = 123456", isDark: isDark, font: .init()))
        let lastValid = model.terminal.theme
        #expect(lastValid.dark == lastValid.light)
        #expect(lastValid.dark.rendered.contains("background = 123456"))
        #expect(!model.update(themeName: name, text: "background = not-a-color", isDark: isDark, font: .init()))
        #expect(model.issue != nil)
        #expect(model.terminal.theme == lastValid)
        #expect(model.update(themeName: name, text: "background = 123456", isDark: isDark, font: .init()))
        #expect(model.issue == nil)
        #expect(model.terminal.theme == lastValid)
        #expect(
            model.update(
                themeName: name, text: "font-size = 30\nbackground = ABCDEF", isDark: isDark,
                font: .init(family: "Menlo", size: 18, sizeFollowsTheme: false)))
        #expect(model.issue == nil)
        #expect(model.terminal.controller === controller)
        #expect(model.terminal.theme.dark.rendered.hasSuffix("font-family = \nfont-family = Menlo\nfont-size = 18"))
        #expect(!model.terminal.isFocused)
    }
}
