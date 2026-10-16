import AgentKit
import AppKit
import SwiftUI
import TermindApplication
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct SettingsCopyRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func builtInServerHasConsistentTitlesWithoutTransportFootnote(_ language: String) async throws {
        let app = AppModel(hosts: HostLibraryModel(), ai: AIConfigurationModel(persistsSecrets: false))
        defer { app.shutdownForTermination() }
        try await capture(
            Form { MCPSettings(edit: { _, _ in }, openServer: {}) }
                .formStyle(.grouped).environment(app),
            language: language, name: "mcp-settings")
        try await capture(
            Form { MCPServerSettings() }.formStyle(.grouped).environment(app),
            language: language, name: "built-in-server")
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func simplifiedSettingsRenderWithoutEmptyRows(_ language: String) async throws {
        let app = AppModel(hosts: HostLibraryModel(), ai: AIConfigurationModel(persistsSecrets: false))
        defer { app.shutdownForTermination() }
        try await capture(
            Form {
                ModelProviderSettings(edit: { _, _ in })
                SkillSettings(edit: { _, _ in })
                WebSearchSettings()
            }.formStyle(.grouped).environment(app),
            language: language, name: "ai-settings")
        var search = app.aiConfiguration.webSearch
        search.prefersBuiltIn.toggle()
        app.aiConfiguration.setWebSearch(search)
        try await capture(
            Form { WebSearchSettings() }.formStyle(.grouped).environment(app),
            language: language, name: "web-search-alternate")

        let window = WindowModel(workspaces: [])
        let provider = ModelProvider(name: "")
        #expect(app.aiConfiguration.saveProvider(provider, endpoint: .init()))
        try await capture(
            ModelProviderEditorPage(modelProviderID: provider.id, isNew: true, showModels: {}, deleted: {})
                .environment(app).environment(window),
            language: language, name: "provider-without-footer")
        for category: SettingsCategory in [.app, .connections, .notifications] {
            window.openSettings(route: .category(category))
            try await capture(
                SettingsPageView().environment(app).environment(window),
                language: language, name: "settings-\(category)", height: category == .app ? 1700 : 1000)
        }
    }

    private func capture(_ view: some View, language: String, name: String, height: CGFloat = 700) async throws {
        let content = view.environment(\.locale, Locale(identifier: language)).frame(width: 680, height: height)
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "\(name)-\(language).png")
    }
}
