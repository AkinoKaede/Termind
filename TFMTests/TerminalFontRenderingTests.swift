import GhosttyTerminal
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct TerminalFontRenderingTests {
    @Test(arguments: [false, true])
    func explicitTypographyOverridesCustomConfigurationForBothAppearances(_ isDark: Bool) {
        let configuration = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: isDark ? "Termind Dark" : "Termind Light",
            customEnabled: true, customText: "font-family = Courier\nfont-size = 30", isDark: isDark,
            font: .init(family: "Menlo", size: 18, sizeFollowsTheme: false))
        #expect(configuration.rendered.hasSuffix("font-family = \nfont-family = Menlo\nfont-size = 18"))
    }

    @Test func familyAndSizeFollowThemeIndependently() {
        func configuration(_ font: TerminalFontPreferences) -> String {
            TermindTerminalThemeCatalog.terminalConfiguration(
                themeName: "Termind Dark", customEnabled: true,
                customText: "font-family = Courier\nfont-size = 30", isDark: true, font: font
            ).rendered
        }
        #expect(configuration(.init()).hasSuffix("font-family = Courier\nfont-size = 30"))
        #expect(configuration(.init(family: "Menlo")).hasSuffix("font-family = \nfont-family = Menlo"))
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
        #expect(state.theme.dark.rendered.hasSuffix("font-family = \nfont-family = Menlo\nfont-size = 18"))
        state.applyPreferences(preferences)
        #expect(state.controller === controller)
        #expect(state.controller.lastConfigurationIssue == nil)
        #expect(state.theme.dark.rendered.hasSuffix("font-family = Courier"))
    }

    @Test func installedMonospacedFamiliesIncludeMenlo() {
        TerminalFontCatalog.shared.refresh()
        #expect(TerminalFontCatalog.shared.families.contains("Menlo"))
        #expect(!TerminalFontCatalog.shared.families.contains("Helvetica"))
    }
}
