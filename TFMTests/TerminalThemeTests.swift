// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import Testing

@testable import Termind

struct TerminalThemeTests {
    @Test
    func appearanceOptionsAreFilteredAndSortedByName() {
        let lightNames = TermindTerminalThemeCatalog.lightThemes.map(\.name)
        let darkNames = TermindTerminalThemeCatalog.darkThemes.map(\.name)

        #expect(lightNames == lightNames.sorted())
        #expect(darkNames == darkNames.sorted())
        #expect(TermindTerminalThemeCatalog.lightThemes.allSatisfy { !$0.isDark })
        #expect(TermindTerminalThemeCatalog.darkThemes.allSatisfy { $0.isDark })
    }

    @Test
    func resolverFallsBackForMissingOrWrongAppearancePreferences() {
        let preferences = TerminalPreferences(
            darkTheme: SettingsKey.defaultTerminalThemeLight,
            lightTheme: "Missing Light Theme"
        )

        let light = TermindTerminalThemeCatalog.resolvedTheme(named: preferences.lightTheme, isDark: false)
        let dark = TermindTerminalThemeCatalog.resolvedTheme(named: preferences.darkTheme, isDark: true)

        #expect(light.name == SettingsKey.defaultTerminalThemeLight)
        #expect(dark.name == SettingsKey.defaultTerminalThemeDark)
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
    }

    @Test
    func changingBaseThemeWithCustomOverlayPreservesOverrideAndChangesUncoveredColors() throws {
        let first = TermindTerminalThemeCatalog.defaultDark
        let second = try #require(
            TermindTerminalThemeCatalog.darkThemes.first {
                $0.name != first.name && $0.foreground != first.foreground
            })

        let firstConfiguration = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: first.name,
            customEnabled: true,
            customText: "background = 010203",
            isDark: true
        )
        let secondConfiguration = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: second.name,
            customEnabled: true,
            customText: "background = 010203",
            isDark: true
        )

        #expect(firstConfiguration.rendered.hasSuffix("background = 010203"))
        #expect(secondConfiguration.rendered.hasSuffix("background = 010203"))
        #expect(firstConfiguration.rendered != secondConfiguration.rendered)
    }

    @Test @MainActor
    func presentingTerminalSettingsDoesNotRewriteUnavailableThemes() async throws {
        let initial = TerminalPreferences(
            darkTheme: SettingsKey.defaultTerminalThemeLight,
            lightTheme: "Missing Light Theme"
        )
        let persistence = RecordingTerminalPreferencesPersistence(initial: initial)
        let terminalSettings = TerminalSettingsModel(persistence: persistence)
        let app = AppModel(hosts: HostLibraryModel(), terminalSettings: terminalSettings)
        let windowModel = WindowModel(workspaces: [])
        windowModel.openSettings(route: .category(.terminal))
        let appearance = AppearanceProbe()
        defer { app.shutdownForTermination() }

        let view = SettingsPageView()
            .environment(app)
            .environment(windowModel)
            .frame(width: 640, height: 1100)
            .onAppear { appearance.count += 1 }
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 1100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer {
            window.contentViewController = nil
            window.close()
        }

        controller.view.layoutSubtreeIfNeeded()
        for _ in 0..<10 where appearance.count == 0 {
            try await Task.sleep(for: .milliseconds(10))
            controller.view.layoutSubtreeIfNeeded()
        }

        #expect(appearance.count > 0)
        #expect(windowModel.settingsRoute == .category(.terminal))
        #expect(terminalSettings.preferences == initial)
        #expect(persistence.saveCount == 0)
    }
}

@MainActor private final class RecordingTerminalPreferencesPersistence: TerminalPreferencesPersisting {
    let initial: TerminalPreferences
    var saveCount = 0

    init(initial: TerminalPreferences) {
        self.initial = initial
    }

    func loadTerminal() throws -> TerminalPreferences { initial }

    func saveTerminal(_ value: TerminalPreferences) throws { saveCount += 1 }
}

@MainActor private final class AppearanceProbe {
    var count = 0
}
