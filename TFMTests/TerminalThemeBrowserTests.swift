// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import GhosttyTerminal
import SwiftUI
import TermindDomain
import TermindPresentation
import Testing

@Suite @MainActor
struct TerminalThemeBrowserTests {
    @Test func scopedThemeSearchKeepsDuplicateNameTieBreaksWithoutChangingTheLibrary() throws {
        let early = TerminalCustomTheme(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            name: "Ocean 2", appearance: .both, baseThemeName: "Termind Dark")
        var late = early
        late.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        late.appearance = .dark
        let tenth = TerminalCustomTheme(name: "Ocean 10", appearance: .light, baseThemeName: "Termind Light")
        let library = TerminalThemeLibrary(themes: [tenth, late, early])
        #expect(library.themes(matching: "  oCEAn\n").map(\.id) == [early.id, late.id, tenth.id])
        let dark = TerminalThemeOptions(preferences: .init(), isDark: true, library: library)
        let light = TerminalThemeOptions(preferences: .init(), isDark: false, library: library)
        #expect(dark.customThemes(matching: "  oCEAn\n").map(\.id) == [early.id, late.id])
        #expect(light.customThemes(matching: " \n ").map(\.id) == [early.id, tenth.id])
        #expect(light.customThemes(matching: "missing").isEmpty)
        #expect(library.themes.map(\.id) == [tenth.id, late.id, early.id])
        #expect(library.selections.isEmpty)
    }

    @Test func customThemeSearchIncludesAllAppearancesButSelectionSearchKeepsItsScope() {
        let light = TerminalCustomTheme(name: "Ocean Day", appearance: .light, baseThemeName: "Termind Light")
        let dark = TerminalCustomTheme(name: "Ocean Night", appearance: .dark, baseThemeName: "Termind Dark")
        let both = TerminalCustomTheme(name: "海洋", appearance: .both, baseThemeName: "Termind Dark")
        let library = TerminalThemeLibrary(themes: [dark, both, light])
        #expect(library.themes(matching: "  oCEAn\n").map(\.id) == [light.id, dark.id])
        #expect(library.themes(matching: "海").map(\.id) == [both.id])
        #expect(library.themes(matching: "missing").isEmpty)
        #expect(library.themes(matching: " \n ").count == 3)
        for isDark in [false, true] {
            let options = TerminalThemeOptions(preferences: .init(), isDark: isDark, library: library)
            #expect(options.customThemes(matching: "Ocean").map(\.id) == [isDark ? dark.id : light.id])
            #expect(options.customThemes(matching: "海").map(\.id) == [both.id])
        }
    }

    @Test func bothUsesExactlyTheSamePaletteInEitherAppearanceAndKeepsTheSavedName() {
        let theme = TerminalCustomTheme(
            name: "Shared palette", appearance: .both, baseThemeName: "Termind Dark",
            configuration: "background = 123456")
        let library = TerminalThemeLibrary(
            themes: [theme],
            selections: [
                .init(appearance: .light, builtInThemeName: "Termind Light", customThemeID: theme.id),
                .init(appearance: .dark, builtInThemeName: "Termind Dark", customThemeID: theme.id),
            ])
        for isDark in [false, true] {
            let options = TerminalThemeOptions(preferences: .init(), isDark: isDark, library: library)
            #expect(options.isAvailable)
            #expect(options.isCustom)
            #expect(options.baseTheme.name == "Termind Dark")
            #expect(options.customThemes(matching: " SHARED ").map(\.id) == [theme.id])
            #expect(options.selectedCustomTheme?.name == "Shared palette")
        }
        let preview = TerminalConfigurationPreviewModel()
        preview.terminal.applyPreferences(.init(), library: library)
        #expect(preview.terminal.theme.light == preview.terminal.theme.dark)
        #expect(preview.terminal.theme.light.rendered.contains("background = 123456"))
    }

    @Test func unavailableBothBaseFallsBackConsistentlyWithoutRewritingTheTheme() {
        let custom = TerminalCustomTheme(name: "Missing", appearance: .both, baseThemeName: "Not installed")
        let library = TerminalThemeLibrary(
            themes: [custom],
            selections: [
                .init(appearance: .light, builtInThemeName: "Termind Light", customThemeID: custom.id),
                .init(appearance: .dark, builtInThemeName: "Termind Dark", customThemeID: custom.id),
            ])
        for isDark in [false, true] {
            let options = TerminalThemeOptions(preferences: .init(), isDark: isDark, library: library)
            #expect(!options.isAvailable)
            #expect(options.baseTheme == TermindTerminalThemeCatalog.defaultDark)
            #expect(options.name == "Not installed")
        }
    }

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
                cursor-text = FFEEDD
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
        #expect(palette.cursorText.hex == "FFEEDD")
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
        let text = """
            background = 123456
            cursor-color = AABBCC
            cursor-text = 112233
            selection-background = 445566
            selection-foreground = FFEEDD
            palette = 15=#ABCDEF
            """
        #expect(model.update(themeName: name, text: text, isDark: isDark, font: .init()))
        let lastValid = model.terminal.theme
        let lastPalette = model.palette
        #expect(lastPalette.cursor.hex == "AABBCC")
        #expect(lastPalette.cursorText.hex == "112233")
        #expect(lastPalette.selection.hex == "445566")
        #expect(lastPalette.selectionForeground.hex == "FFEEDD")
        #expect(lastPalette.ansi[15].hex == "ABCDEF")
        #expect(lastValid.dark == lastValid.light)
        #expect(lastValid.dark.rendered.contains("background = 123456"))
        #expect(!model.update(themeName: name, text: "background = not-a-color", isDark: isDark, font: .init()))
        #expect(model.issue != nil)
        #expect(model.terminal.theme == lastValid)
        #expect(model.palette == lastPalette)
        #expect(model.update(themeName: name, text: text, isDark: isDark, font: .init()))
        #expect(model.issue == nil)
        #expect(model.terminal.theme == lastValid)
        #expect(model.palette == lastPalette)
        let fontText = "font-family = Courier\nfont-family = Helvetica\nfont-size = 30\nbackground = ABCDEF"
        let font = TerminalFontPreferences(family: "Menlo", size: 18, sizeFollowsTheme: false)
        #expect(model.update(themeName: name, text: fontText, isDark: isDark, font: font))
        #expect(model.issue == nil)
        #expect(model.terminal.controller === controller)
        #expect(model.terminal.theme.dark.rendered.hasSuffix("font-family = Menlo\n" + fontText + "\nfont-size = 18"))
        let state = TerminalViewState()
        state.applyPreferences(
            .init(
                darkTheme: name, lightTheme: name,
                darkCustomEnabled: true, lightCustomEnabled: true,
                darkCustomConfiguration: fontText, lightCustomConfiguration: fontText),
            font: font)
        #expect(model.terminal.theme.dark == (isDark ? state.theme.dark : state.theme.light))
        #expect(!model.terminal.isFocused)
    }
}
