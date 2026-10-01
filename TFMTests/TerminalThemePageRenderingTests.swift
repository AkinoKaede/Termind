import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

/// Offscreen hosting leaves the user's windows and keyboard focus untouched.
@Suite(.serialized) @MainActor
struct TerminalThemePageRenderingTests {
    @Test(.requiresVisibleWindow, arguments: ["en", "zh-Hans"])
    func nativeThemeBrowserAndEditor(language: String) async throws {
        let model = TerminalSettingsModel()
        model.selectCustomTheme(isDark: true)
        model.set("background = 152033\nforeground = E7EDF7\npalette = 2=#7BD88F", for: \.darkCustomConfiguration)
        let app = AppModel(hosts: HostLibraryModel(), terminalSettings: model)
        defer { app.shutdownForTermination() }
        let navigation = WindowModel(workspaces: [])
        navigation.openSettings(route: .terminalThemes(.dark))
        let controller = NSHostingController(
            rootView: SettingsPageView().environment(app).environment(navigation)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, .dark)
                .frame(width: 900, height: 700))
        let window = NSWindow(
            contentRect: CGRect(x: 80, y: 80, width: 900, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        window.title = "Termind Theme Preview"
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        for editor in [false, true] {
            if editor { navigation.settingsRoute = .terminalConfiguration(.dark) }
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(800))
            // The screenshot runner captures the compositor output: cacheDisplay cannot capture Liquid Glass.
            print("TERMIND_THEME_WINDOW|\(window.windowNumber)|\(language)-\(editor ? "editor" : "browser")")
            try await Task.sleep(for: .seconds(3))
            #expect(navigation.settingsRoute == (editor ? .terminalConfiguration(.dark) : .terminalThemes(.dark)))
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func browserRendersBothAppearancesWithoutChangingTheSelection(language: String, isDark: Bool) async throws {
        let initial = TerminalPreferences(darkCustomEnabled: true, lightCustomEnabled: true)
        let model = TerminalSettingsModel()
        model.applyRemoteSnapshot(initial)
        let app = AppModel(hosts: HostLibraryModel(), terminalSettings: model)
        defer { app.shutdownForTermination() }
        let windowModel = WindowModel(workspaces: [])
        windowModel.openSettings(route: .terminalThemes(isDark ? .dark : .light))
        let content = SettingsPageView().environment(app).environment(windowModel)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, isDark ? .dark : .light)
            .frame(width: 760, height: 720)
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        window.contentViewController = controller
        defer {
            window.contentViewController = nil
            window.close()
        }
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let name = "theme-browser-\(language)-\(isDark ? "dark" : "light").png"
        Attachment.record(data, named: name)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termind-theme-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
        #expect(data.count > 10_000)
        #expect(model.preferences == initial)
        #expect(!window.isVisible)
    }
}
