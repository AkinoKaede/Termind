import AppKit
import GhosttyTerminal
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct TerminalFontRenderingTests {
    @Test(arguments: [false, true])
    func preferredFontPrecedesThemeFallbacksAndManualSizeWins(_ isDark: Bool) {
        let configuration = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: isDark ? "Termind Dark" : "Termind Light",
            customEnabled: true,
            customText: "font-family = Courier\nfont-family = Helvetica\nfont-size = 30", isDark: isDark,
            font: .init(family: "Menlo", size: 18, sizeFollowsTheme: false))
        #expect(
            configuration.rendered.hasSuffix(
                "font-family = Menlo\nfont-family = Courier\nfont-family = Helvetica\nfont-size = 30\nfont-size = 18"))
    }

    @Test(arguments: [false, true], ["", "\"\""])
    func themeResetsRetainPreferredFontAndDoNotRestoreClearedFallbacks(_ isDark: Bool, reset: String) {
        let text = """
            font-family = Courier
            font-family = \(reset)
            font-family = Helvetica
            font-family = \(reset)
            font-family = "Courier New"
            """
        let preferences = TerminalPreferences(
            darkCustomEnabled: true, lightCustomEnabled: true,
            darkCustomConfiguration: text, lightCustomConfiguration: text)
        let state = TerminalViewState()
        state.applyPreferences(preferences, font: .init(family: "Menlo"))
        let configuration = isDark ? state.theme.dark : state.theme.light
        #expect(
            configuration.rendered.hasSuffix(
                """
                font-family = Menlo
                font-family = Courier
                font-family = \(reset)
                font-family = Menlo
                font-family = Helvetica
                font-family = \(reset)
                font-family = Menlo
                font-family = "Courier New"
                """))
        #expect(state.controller.lastConfigurationIssue == nil)
    }

    @Test(arguments: [false, true], ["", "Missing Font"])
    func followingThemeOrUnavailableFontPreservesThemeEntries(_ isDark: Bool, family: String) {
        let text = "font-family = Courier\nfont-family = \"\"\nfont-family = Helvetica"
        let configuration = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: isDark ? "Termind Dark" : "Termind Light",
            customEnabled: true, customText: text, isDark: isDark,
            font: TerminalFontPreferences(family: family).resolvingFamily(in: ["Menlo"]))
        #expect(configuration.rendered.hasSuffix(text))
        #expect(fontFamilies(in: configuration) == ["Courier", "\"\"", "Helvetica"])
    }

    @Test(arguments: [false, true])
    func disabledCustomConfigurationDoesNotContributeFallbacks(_ isDark: Bool) {
        let configuration = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: isDark ? "Termind Dark" : "Termind Light",
            customEnabled: false, customText: "font-family = Courier", isDark: isDark,
            font: .init(family: "Helvetica"))
        #expect(fontFamilies(in: configuration) == ["Helvetica"])
    }

    @Test(arguments: [false, true])
    func themeWithoutFontFamiliesStillUsesPreferredFamily(_ isDark: Bool) {
        let configuration = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: isDark ? "Termind Dark" : "Termind Light",
            customEnabled: true, customText: "background = 123456\nfont-size = 30", isDark: isDark,
            font: .init(family: "Helvetica"))
        #expect(configuration.rendered.hasSuffix("font-family = Helvetica\nbackground = 123456\nfont-size = 30"))
    }

    @Test func themeStylesOtherOptionsAndDuplicateFamiliesRemainUnchanged() {
        let text = """
            font-family = "Courier New"
            font-family-bold = Courier
            font-family-italic = Helvetica
            font-family-bold-italic = "Courier New"
            font-family = Menlo
            font-family = "Courier New"
            background = 123456
            """
        let configuration = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: "Termind Dark", customEnabled: true, customText: text, isDark: true,
            font: .init(family: "Menlo"))
        #expect(configuration.rendered.hasSuffix("font-family = Menlo\n" + text))
        #expect(fontFamilies(in: configuration) == ["Menlo", "\"Courier New\"", "Menlo", "\"Courier New\""])
    }

    @Test func familyAndSizeFollowThemeIndependently() {
        func configuration(_ font: TerminalFontPreferences) -> String {
            TermindTerminalThemeCatalog.terminalConfiguration(
                themeName: "Termind Dark", customEnabled: true,
                customText: "font-family = Courier\nfont-size = 30", isDark: true, font: font
            ).rendered
        }
        #expect(configuration(.init()).hasSuffix("font-family = Courier\nfont-size = 30"))
        #expect(
            configuration(.init(family: "Menlo"))
                .hasSuffix("font-family = Menlo\nfont-family = Courier\nfont-size = 30"))
        let manualSize = configuration(.init(size: 18, sizeFollowsTheme: false))
        #expect(manualSize.hasSuffix("font-size = 18"))
        #expect(!manualSize.contains("font-family = \n"))
    }

    @Test func changingTypographyReconfiguresTheSameControllerAndCanReturnToTheme() {
        let state = TerminalViewState()
        let controller = state.controller
        let preferences = TerminalPreferences(darkCustomEnabled: true, darkCustomConfiguration: "font-family = Courier")
        state.applyPreferences(preferences, font: .init(family: "Menlo", size: 18, sizeFollowsTheme: false))
        #expect(state.controller === controller)
        #expect(state.controller.lastConfigurationIssue == nil)
        #expect(state.theme.dark.rendered.hasSuffix("font-family = Menlo\nfont-family = Courier\nfont-size = 18"))
        state.applyPreferences(preferences)
        #expect(state.controller === controller)
        #expect(state.controller.lastConfigurationIssue == nil)
        #expect(state.theme.dark.rendered.hasSuffix("font-family = Courier"))
    }

    private func fontFamilies(in configuration: GhosttyTerminal.TerminalConfiguration) -> [String] {
        TerminalCustomConfiguration(configuration.rendered).entries
            .filter { $0.key == "font-family" }.map(\.value)
    }
}
