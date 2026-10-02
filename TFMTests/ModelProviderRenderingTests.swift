import AgentKit
import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct ModelProviderRenderingTests {
    @Test(.requiresVisibleWindow, arguments: ["en", "zh-Hans", "zh-Hant"])
    func blankNameFormsPreviewTheSavedDefaults(_ language: String) async throws {
        let host = TermindDomain.Host(name: "AWS", host: "example.invalid")
        let enclave = SSHKeyRef(label: "", algorithm: .ecdsa256, storage: .secureEnclave)
        let app = AppModel(hosts: HostLibraryModel(hosts: [host], keys: [enclave]))
        defer { app.shutdownForTermination() }
        try await capture(
            Form {
                HostOrganizationSection(host: .constant(.init(name: "", host: "example.invalid"))) {
                    EmptyView()
                } tagsField: {
                    EmptyView()
                }
                HostConnectionFields(host: .constant(.init(name: "", host: "example.invalid")))
                PortForwardingFields(rule: .constant(.init(hostID: host.id)), hosts: [host])
            }.formStyle(.grouped), language: language, name: "name-hints")
        try await capture(
            NewIdentitySheet(identity: Identity(name: "", username: "deploy")) { _, _ in }.environment(app),
            language: language, name: "identity-name-hint")
        try await capture(
            KeychainGenerateDetail().environment(app).environment(WindowModel()),
            language: language, name: "key-name-hint")
        try await capture(
            KeychainEditDetail(keyID: enclave.id).environment(app).environment(WindowModel()),
            language: language, name: "enclave-name-hint")
    }

    @Test(.requiresVisibleWindow, arguments: ["en", "zh-Hans", "zh-Hant"])
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

    @Test(.requiresVisibleWindow, arguments: ["en", "zh-Hans", "zh-Hant"])
    func newProviderHintsAndVertexFieldsRender(_ language: String) async throws {
        let ai = AIConfigurationModel(persistsSecrets: false)
        let provider = ModelProvider(name: "")
        #expect(ai.saveProvider(provider, endpoint: .init()))
        let app = AppModel(hosts: HostLibraryModel(), ai: ai)
        defer { app.shutdownForTermination() }
        try await capture(
            ModelProviderEditorPage(modelProviderID: provider.id, isNew: true, showModels: {}, deleted: {}).environment(
                app),
            language: language, name: "new-hints")
        var vertex = ModelProvider(name: "Google", usesVertex: true)
        vertex.vertex = VertexConfig(
            projectID: "fixture-project", location: "global",
            credentialRef: "fixture-reference", clientEmail: "fixture@example.invalid")
        #expect(ai.saveProvider(vertex, endpoint: .init(apiType: .generateContent)))
        try await capture(
            ModelProviderEditorPage(modelProviderID: vertex.id, showModels: {}, deleted: {}).environment(app),
            language: language, name: "vertex")
    }

    @Test func newEditorKeepsEmptyBuffersWhileReopeningReadsSavedDefaults() throws {
        let ai = AIConfigurationModel(persistsSecrets: false)
        let provider = ModelProvider(name: "")
        #expect(ai.saveProvider(provider, endpoint: .init()))
        let saved = try #require(ai.modelProvider(provider.id))
        let newSession = ModelProviderEditorSession()
        newSession.begin(with: saved, in: ai, isNew: true)
        #expect(newSession.name.isEmpty)
        #expect(newSession.endpoint.url.isEmpty)
        let reopened = ModelProviderEditorSession()
        reopened.begin(with: saved, in: ai)
        #expect(reopened.name == "OpenAI")
        #expect(reopened.endpoint.url == ModelAPIType.automatic.defaultURL)
        #expect(!SettingsDraftPolicy.shouldDiscard(saved))
    }

    @Test func modelAutosaveKeepsTheEmptyInputAndReopeningShowsTheSavedName() throws {
        let first = AIModel(id: "first", displayName: "Custom")
        let second = AIModel(id: "second", displayName: "Catalog Name")
        let provider = ModelProvider(name: "Gateway", models: [first, second])
        let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        let session = ModelNameEditorSession()
        session.begin(with: first)
        session.save("", model: first, providerID: provider.id, in: ai)
        #expect(session.name == "")
        #expect(ai.modelProvider(provider.id)?.model(first.id)?.displayName == first.id)
        session.begin(with: ai.modelProvider(provider.id)?.model(first.id))
        #expect(session.name == "")
        session.save("Renamed", model: first, providerID: provider.id, in: ai)
        #expect(ai.modelProvider(provider.id)?.model(first.id)?.displayName == "Renamed")
        session.save(" \t", model: first, providerID: provider.id, in: ai)
        #expect(session.name == " \t")
        session.begin(with: second)
        #expect(session.name == "Catalog Name")
        session.begin(with: ai.modelProvider(provider.id)?.model(first.id))
        #expect(session.name == first.id)
        let reopened = ModelNameEditorSession()
        reopened.begin(with: ai.modelProvider(provider.id)?.model(first.id))
        #expect(reopened.name == first.id)
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
    }
}
