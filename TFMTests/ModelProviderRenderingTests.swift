import AgentKit
import AppKit
import SwiftUI
import TermindApplication
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct ModelProviderRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func anonymousProviderSettingsAndModelsRender(_ language: String) async throws {
        let provider = ModelProvider(
            name: "Local Model", inferenceURL: "http://localhost:11434/v1/chat/completions",
            baseURL: "http://localhost:11434/v1", models: [AIModel(id: "local-model")])
        let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        let app = AppModel(hosts: HostLibraryModel(), ai: ai)
        defer { app.shutdownForTermination() }
        try await capture(
            ModelProviderEditorPage(modelProviderID: provider.id, showModels: {}, deleted: {}).environment(app),
            language: language, name: "provider")
        try await capture(
            ModelListEditor(modelProviderID: provider.id).environment(app), language: language, name: "models")
        try await capture(
            Form { ModelProviderSettings(edit: { _, _ in }) }.formStyle(.grouped).environment(app),
            language: language, name: "provider-list")
    }

    private func capture(_ view: some View, language: String, name: String) async throws {
        let content = view.environment(\.locale, Locale(identifier: language)).frame(width: 680, height: 700)
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 700),
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
        Attachment.record(data, named: "keyless-\(name)-\(language).png")
        #expect(data.count > 10_000)
    }
}
