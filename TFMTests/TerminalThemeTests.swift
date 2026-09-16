import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

struct TerminalThemeTests {
    @Test
    func unavailableThemesFallBackForBothAppearances() {
        let light = TermindTerminalThemeCatalog.background(
            themeName: "Missing Light Theme",
            customEnabled: false,
            customText: "",
            isDark: false
        )
        let dark = TermindTerminalThemeCatalog.background(
            themeName: "Missing Dark Theme",
            customEnabled: false,
            customText: "",
            isDark: true
        )

        #expect(light == TermindTerminalPalette.termindLight.background)
        #expect(dark == TermindTerminalPalette.termindDark.background)
    }

    @Test
    func customConfigurationParsesGhosttyLinesInOrder() {
        let configuration = TerminalCustomConfiguration(
            """
            # comment

              background = #102030
            palette = 1=#AA0000
            invalid line
            custom-key = value=with=equals
            = missing-key
            background = 405060
            """
        )

        #expect(
            configuration.entries == [
                .init(key: "background", value: "#102030"),
                .init(key: "palette", value: "1=#AA0000"),
                .init(key: "custom-key", value: "value=with=equals"),
                .init(key: "background", value: "405060"),
            ]
        )
        #expect(configuration.lastValue(for: "background") == "405060")
    }

    @Test
    func customBackgroundUsesLastValidSetting() {
        let background = TermindTerminalThemeCatalog.background(
            themeName: SettingsKey.defaultTerminalThemeDark,
            customEnabled: true,
            customText: "background = #102030\nbackground = A0B0C0",
            isDark: true
        )

        #expect(background.hex == "A0B0C0")
    }

    @Test
    func invalidCustomBackgroundFallsBackToSelectedTheme() {
        let background = TermindTerminalThemeCatalog.background(
            themeName: SettingsKey.defaultTerminalThemeLight,
            customEnabled: true,
            customText: "background = transparent",
            isDark: false
        )

        #expect(background == TermindTerminalPalette.termindLight.background)
    }

    @Test
    func disabledCustomConfigurationIgnoresItsBackground() {
        let background = TermindTerminalThemeCatalog.background(
            themeName: SettingsKey.defaultTerminalThemeDark,
            customEnabled: false,
            customText: "background = FFFFFF",
            isDark: true
        )

        #expect(background == TermindTerminalPalette.termindDark.background)
    }
}
