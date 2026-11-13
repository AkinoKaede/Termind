// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindDomain
import TermindPresentation
import Testing

struct TerminalFontChoicesTests {
    @Test func groupsOnlyAvailableFamiliesAndRemovesDuplicates() {
        let choices = TerminalFontChoices(
            families: ["Menlo", "SauceCodePro Nerd Font", "", "FiraCode Nerd Font", "Menlo", "FiraCode Nerd Font"],
            builtInFamilies: TerminalBundledFonts.families)
        #expect(choices.builtIn == ["FiraCode Nerd Font", "SauceCodePro Nerd Font"])
        #expect(choices.system == ["Menlo"])
        let missing = TerminalFontChoices(families: ["Menlo"], builtInFamilies: TerminalBundledFonts.families)
        #expect(missing.builtIn.isEmpty)
        #expect(missing.system == ["Menlo"])
        #expect(
            TerminalFontPreferences(family: "SauceCodePro Nerd Font")
                .resolvingFamily(in: missing.system).family.isEmpty)
    }

    @Test func systemFontsRemainSelectableWithoutBundledMetadata() {
        let choices = TerminalFontChoices(
            families: ["Menlo", "Courier New", "Menlo"], builtInFamilies: [])
        #expect(choices.builtIn.isEmpty)
        #expect(choices.system == ["Courier New", "Menlo"])
        #expect(
            TerminalFontPreferences(family: "Courier New")
                .resolvingFamily(in: choices.system).family == "Courier New")
    }

    @Test func jetBrainsMonoAppearsOnceInBuiltInAndSurvivesAvailabilityResolution() {
        let choices = TerminalFontChoices(
            families: ["JetBrains Mono", "Menlo", "JetBrains Mono", "FiraCode Nerd Font"],
            builtInFamilies: TerminalBundledFonts.families)
        #expect(choices.builtIn == ["FiraCode Nerd Font", "JetBrains Mono"])
        #expect(choices.system == ["Menlo"])
        #expect(
            TerminalFontPreferences(family: "JetBrains Mono")
                .resolvingFamily(in: choices.builtIn + choices.system).family == "JetBrains Mono")
    }
}
