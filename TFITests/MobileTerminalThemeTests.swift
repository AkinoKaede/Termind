import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileTerminalThemeTests {
    @Test func editorSeparatesDestructiveDeleteFromImportOnlyForSavedThemes() throws {
        let model = TerminalSettingsModel()
        let theme = TerminalCustomTheme(name: "Personal", appearance: .both, baseThemeName: "Termind Dark")
        let draft = TerminalCustomThemeDraft(theme, isNew: true)
        let editor = MobileCustomThemeEditorSheet(draft: draft, model: model)
        #expect(editor.editorActions.map(\.id) == ["import"])
        #expect(draft.save(in: model))
        let actions = editor.editorActions
        #expect(actions.map(\.id) == ["import", "delete"])
        let delete = try #require(actions.last)
        #expect(delete.role == .destructive)
        #expect(delete.startsGroup)
        model.deleteCustomTheme(id: theme.id)
        #expect(editor.editorActions.map(\.id) == ["import"])
    }

    @Test(
        .requiresKeyWindow,
        arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func themeBrowserSnapshots(language: String, isDark: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let model = TerminalSettingsModel()
        let theme = TerminalCustomTheme(
            name: "Personal", appearance: .both, baseThemeName: "Termind Dark", configuration: "background = 123456")
        model.saveCustomTheme(theme, isNew: true)
        model.selectCustomTheme(id: theme.id, isDark: isDark)
        let initial = model.preferences
        let controller = UIHostingController(
            rootView: NavigationStack { MobileTerminalThemeView(model: model, isDark: isDark) }
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, isDark ? .dark : .light)
                .environment(\.dynamicTypeSize, language == "zh-Hant" ? .accessibility1 : .large))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        Attachment.record(data, named: "mobile-themes-\(language)-\(isDark ? "dark" : "light").png")
        #expect(model.preferences == initial)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termind-theme-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(
            to: directory.appendingPathComponent("mobile-themes-\(language)-\(isDark ? "dark" : "light").png"))
    }

    @Test(.requiresKeyWindow, arguments: ["en", "zh-Hans"], [false, true])
    func customThemeManagerAndEditorSnapshots(language: String, editor: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let model = TerminalSettingsModel()
        let theme = TerminalCustomTheme(
            name: "Ocean", appearance: .both, baseThemeName: "Termind Dark",
            configuration: "background = 152033\nforeground = E7EDF7\npalette = 2=#7BD88F")
        model.saveCustomTheme(theme, isNew: true)
        model.saveCustomTheme(
            .init(name: "Daylight", appearance: .light, baseThemeName: "Termind Light"), isNew: true)
        model.selectCustomTheme(id: theme.id, isDark: true)
        model.selectCustomTheme(id: theme.id, isDark: false)
        let initial = model.themeLibrary
        let draft = TerminalCustomThemeDraft(theme, isNew: false)
        let content = Group {
            if editor {
                EditorSheetPreview(model: model, draft: draft)
            } else {
                NavigationStack { MobileCustomThemesView(model: model) }
            }
        }
        .environment(\.locale, Locale(identifier: language))
        .mobileOperationConfirmations()
        let controller = UIHostingController(rootView: content)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        if editor {
            let sheet = try #require(controller.presentedViewController)
            #expect(sheet.sheetPresentationController != nil)
            let navigation = try #require(navigationController(in: sheet))
            #expect(
                navigation.topViewController?.navigationItem.title
                    == AppLocalization.resolve(AppStrings.Settings.customThemes, locale: Locale(identifier: language)))
        } else {
            let navigation = try #require(navigationController(in: controller))
            let search = try #require(navigation.topViewController?.navigationItem.searchController)
            #expect(
                search.searchBar.placeholder
                    == AppLocalization.resolve(AppStrings.Settings.searchThemes, locale: Locale(identifier: language)))
            #expect(navigation.topViewController?.navigationItem.hidesSearchBarWhenScrolling == false)
            let labels = accessibilityLabels(in: window)
            #expect(labels.contains { $0.contains(theme.name) })
            for resource in [AppStrings.Settings.lightTheme, AppStrings.Settings.darkTheme, AppStrings.Common.edit] {
                let unwanted = AppLocalization.resolve(resource, locale: Locale(identifier: language))
                #expect(!labels.contains { $0.contains(unwanted) })
            }
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        let name = "mobile-custom-\(editor ? "editor" : "library")-\(language).png"
        Attachment.record(data, named: name)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termind-theme-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
        if editor, let sheet = controller.presentedViewController {
            let form = try #require(scrollViews(in: sheet.view).max { $0.bounds.height < $1.bounds.height })
            let bottom = max(-form.adjustedContentInset.top, form.contentSize.height - form.bounds.height)
            form.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await Task.sleep(for: .milliseconds(250))
            let terminal = try #require(terminalView(in: sheet.view))
            if case .inMemory(let session) = terminal.configuration.backend {
                let text = try #require(session.readViewportText())
                #expect(text.contains("user@server"))
                #expect(text.contains("Aa Bb"))
            } else {
                Issue.record("A theme preview must not create a shell session.")
            }
            let previewData = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            Attachment.record(previewData, named: "mobile-custom-preview-\(language).png")
        }
        #expect(model.themeLibrary == initial)
        #expect(!draft.isDirty)
    }

    @Test func previewingDraftDoesNotApplyOrEnableIt() {
        let model = TerminalSettingsModel()
        let initial = model.preferences
        let preview = TerminalConfigurationPreviewModel()
        #expect(
            preview.update(
                themeName: initial.lightTheme, text: "background = 123456", isDark: false, font: .init()))
        #expect(model.preferences == initial)
        #expect(!model.preferences.lightCustomEnabled)
        #expect(!preview.terminal.isFocused)
    }

    private struct EditorSheetPreview: View {
        let model: TerminalSettingsModel
        let draft: TerminalCustomThemeDraft
        @State private var isPresented = false

        var body: some View {
            NavigationStack { MobileCustomThemesView(model: model) }
                .sheet(isPresented: $isPresented) {
                    MobileCustomThemeEditorSheet(draft: draft, model: model)
                }
                .onAppear { isPresented = true }
        }
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { navigationController(in: $0) }.first
    }

    private func accessibilityLabels(in root: NSObject) -> [String] {
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: NSObject) -> [String] {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return [] }
            var children: [NSObject] = (element as? UIView)?.subviews ?? []
            let count = element.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children += (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject }
            }
            return [element.accessibilityLabel].compactMap { $0 } + children.flatMap(visit)
        }
        return visit(root)
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        let scroll = (view as? UIScrollView).map { [$0] } ?? []
        return scroll + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func terminalView(in view: UIView) -> UITerminalView? {
        if let terminal = view as? UITerminalView { return terminal }
        return view.subviews.lazy.compactMap { terminalView(in: $0) }.first
    }
}
