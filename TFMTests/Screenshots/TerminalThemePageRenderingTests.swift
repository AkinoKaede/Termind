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
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_THEME_SCREENSHOTS"] == "1"),
        arguments: ["en", "zh-Hans"], [CGFloat(650), CGFloat(1000)])
    func captureCustomThemeChrome(language: String, width: CGFloat) async throws {
        let model = TerminalSettingsModel()
        let app = AppModel(hosts: HostLibraryModel(), terminalSettings: model)
        defer { app.shutdownForTermination() }
        let navigation = WindowModel(workspaces: [])
        navigation.openSettings(route: .terminalCustomThemes)
        let dark = language == "zh-Hans"
        let content = NavigationStack {
            SettingsPageView()
                .background { WindowToolbarSearchHost() }
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) { WindowToolbarLeadingActions() }
                    ToolbarItem(placement: .primaryAction) { WindowToolbarTrailingActions() }
                }
        }
        .environment(app).environment(navigation)
        .environment(\.locale, Locale(identifier: language))
        .environment(\.colorScheme, dark ? .dark : .light)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 720),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.setContentSize(CGSize(width: width, height: 720))
        defer {
            window.contentViewController = nil
            window.close()
        }
        let theme = TerminalCustomTheme(
            name: "Ocean", appearance: .both, baseThemeName: "Termind Dark",
            configuration: "background = 152033\nforeground = E7EDF7\npalette = 2=#7BD88F")
        for page in ["empty", "library", "search", "editor"] {
            if page == "library" { model.saveCustomTheme(theme, isNew: true) }
            if page == "search" { navigation.customThemeQuery = "missing" }
            if page == "editor" { navigation.beginEditingTerminalTheme(theme, isNew: false, in: model) }
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(450))
            let frame = try #require(window.contentView?.superview)
            frame.layoutSubtreeIfNeeded()
            #expect(window.toolbar != nil)
            let searchFields = descendants(in: frame, ofType: NSSearchField.self)
            if page == "editor" {
                #expect(searchFields.isEmpty)
            } else {
                let search = try #require(searchFields.first)
                #expect(searchFields.count == 1)
                #expect(search.bounds.width > 100)
                #expect(search.isEnabled)
                #expect(
                    search.placeholderString
                        == AppLocalization.resolve(
                            AppStrings.Settings.searchThemes, locale: Locale(identifier: language)))
                #expect(search.stringValue == navigation.customThemeQuery)
                if page == "library" {
                    search.stringValue = " oCEAn "
                    search.delegate?.controlTextDidChange?(
                        Notification(name: NSControl.textDidChangeNotification, object: search))
                    #expect(model.themeLibrary.themes(matching: navigation.customThemeQuery).map(\.id) == [theme.id])
                    #expect(navigation.customThemeQuery == " oCEAn ")
                    search.stringValue = ""
                    search.delegate?.controlTextDidChange?(
                        Notification(name: NSControl.textDidChangeNotification, object: search))
                    #expect(navigation.customThemeQuery.isEmpty)
                }
            }
            let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(data, named: "custom-\(page)-\(language)-\(Int(width)).png")
        }
        #expect(!window.isVisible)
    }

    private func descendants<T: NSView>(in view: NSView, ofType type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(in: $0, ofType: type) }
    }

    @Test(.requiresVisibleWindow, arguments: ["en", "zh-Hans"])
    func nativeThemeBrowserAndEditor(language: String) async throws {
        let model = TerminalSettingsModel()
        let theme = TerminalCustomTheme(
            name: "Ocean", appearance: .both, baseThemeName: "Termind Dark",
            configuration: "background = 152033\nforeground = E7EDF7\npalette = 2=#7BD88F")
        model.saveCustomTheme(theme, isNew: true)
        model.selectCustomTheme(id: theme.id, isDark: true)
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
            if editor {
                navigation.terminalThemeDraft = .init(theme, isNew: false)
                navigation.settingsRoute = .terminalCustomTheme(theme.id)
            }
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(800))
            // The screenshot runner captures the compositor output: cacheDisplay cannot capture Liquid Glass.
            print("TERMIND_THEME_WINDOW|\(window.windowNumber)|\(language)-\(editor ? "editor" : "browser")")
            try await Task.sleep(for: .seconds(3))
            #expect(navigation.settingsRoute == (editor ? .terminalCustomTheme(theme.id) : .terminalThemes(.dark)))
        }
    }

    // This matrix produces images for manual comparison; theme behavior is covered by
    // TerminalThemeBrowserTests and TerminalThemeSelectionTests in the default suite.
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_THEME_SCREENSHOTS"] == "1"),
        arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func captureBrowserAppearances(language: String, isDark: Bool) async throws {
        let model = TerminalSettingsModel()
        let theme = TerminalCustomTheme(
            name: "Ocean", appearance: .both, baseThemeName: "Termind Dark",
            configuration: "background = 152033\nforeground = E7EDF7\npalette = 2=#7BD88F")
        model.saveCustomTheme(theme, isNew: true)
        model.saveCustomTheme(
            .init(name: "Daylight", appearance: .light, baseThemeName: "Termind Light"), isNew: true)
        model.selectCustomTheme(id: theme.id, isDark: isDark)
        let initial = model.themeLibrary
        let app = AppModel(hosts: HostLibraryModel(), terminalSettings: model)
        defer { app.shutdownForTermination() }
        let windowModel = WindowModel(workspaces: [])
        windowModel.openSettings(route: .terminalThemes(isDark ? .dark : .light))
        let content = SettingsPageView().environment(app).environment(windowModel)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, isDark ? .dark : .light)
            .frame(width: 760, height: 720)
        let controller = NSHostingController(rootView: content)
        controller.view.frame = CGRect(x: 0, y: 0, width: 760, height: 720)
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
        for page in ["browser", "library", "editor"] {
            if page == "library" { windowModel.settingsRoute = .terminalCustomThemes }
            if page == "editor" {
                windowModel.terminalThemeDraft = .init(theme, isNew: false)
                windowModel.settingsRoute = .terminalCustomTheme(theme.id)
            }
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            controller.view.layoutSubtreeIfNeeded()
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = "theme-\(page)-\(language)-\(isDark ? "dark" : "light").png"
            Attachment.record(data, named: name)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termind-theme-previews")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name))
        }
        #expect(model.themeLibrary == initial)
        #expect(!window.isVisible)
    }
}
