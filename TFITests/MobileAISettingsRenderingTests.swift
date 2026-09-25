import AgentKit
import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

/// Opt-in native snapshots: set TERMIND_AI_SCREENSHOTS in the test runner environment.
/// Uses the shipping views and a disposable in-memory app, without accounts or network requests.
@Suite(.serialized) @MainActor
struct MobileAISettingsRenderingTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_AI_SCREENSHOTS"] != nil),
        arguments: ["en", "zh-Hans", "zh-Hant"]
    )
    func existingProviderKeyIsEditedDirectly(_ language: String) async throws {
        let provider = ModelProvider(
            name: "Model Provider", inferenceURL: "https://example.invalid/v1", credentialRef: "fixture-key")
        let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        ai.setSecret("fixture-api-key", for: "fixture-key")
        try await capture(
            "provider-direct-key", language: language,
            view: MobileProviderEditor(ai: ai, provider: provider).environment(\.locale, Locale(identifier: language)))
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func anonymousProviderEditorShowsOptionalKey(_ language: String) async throws {
        let ai = AIConfigurationModel()
        let provider = ModelProvider(name: "Local Model", inferenceURL: "http://localhost:11434/v1")
        try await capture(
            "anonymous-provider", language: language,
            view: MobileProviderEditor(ai: ai, provider: provider).environment(\.locale, Locale(identifier: language)))
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func newHintsAndVertexEditorRender(_ language: String) async throws {
        let ai = AIConfigurationModel(persistsSecrets: false)
        try await capture(
            "provider-hints", language: language,
            view: MobileProviderEditor(ai: ai, provider: ModelProvider(name: ""))
                .environment(\.locale, Locale(identifier: language)))
        let provider = ModelProvider(
            name: "Google", usesVertex: true,
            vertex: VertexConfig(
                projectID: "fixture-project", credentialRef: "fixture-reference",
                clientEmail: "fixture@example.invalid"))
        #expect(ai.saveProvider(provider, endpoint: .init(apiType: .generateContent)))
        try await capture(
            "provider-vertex", language: language,
            view: MobileProviderEditor(ai: ai, provider: try #require(ai.modelProvider(provider.id)))
                .environment(\.locale, Locale(identifier: language)))
    }

    @Test func renderSettingsEditors() async throws {
        guard let language = ProcessInfo.processInfo.environment["TERMIND_AI_SCREENSHOTS"] else { return }
        let app = try MobileAppModel(inMemory: true)
        var provider = ModelProvider(
            name: "Research Gateway — Long Provider Name", inferenceURL: "https://example.invalid/v1/responses")
        var model = AIModel(id: "research-chat-with-a-long-model-identifier")
        model.displayName = "Research Chat"
        model.abilities = [.reasoning, .toolCall]
        model.contextLength = 128000
        provider.models = [model, AIModel(id: "compact-chat")]
        app.ai.upsert(provider)
        let skill = AgentSkill(
            name: "disk-triage", title: "Disk Triage", summary: "Inspect disk usage and identify safe next steps.",
            body: "# Disk Triage\n\n1. Inspect disk usage.\n2. Explain the findings before making changes.")
        app.skills.upsert(skill)
        var tool = MCPTool(id: "search_documentation")
        tool.summary =
            "Find relevant documentation across every connected source and return the most useful matching sections."
        let server = MCPServer(
            name: "Documentation", url: "https://example.invalid/teams/platform/documentation/model-context-protocol",
            headers: [MCPHeader(name: "X-Tenant", value: "platform")], tools: [tool])
        app.ai.upsert(server)
        var disabledServer = MCPServer(
            name: "Disabled Documentation Mirror",
            url: "https://backup.example.invalid/teams/platform/documentation/model-context-protocol")
        disabledServer.isEnabled = false
        app.ai.upsert(disabledServer)
        let locale = Locale(identifier: language)
        try await capture(
            "ai", language: language,
            view: NavigationStack { MobileAISettingsView(app: app) }.environment(\.locale, locale))
        try await capture(
            "models-page", language: language,
            view: NavigationStack { MobileModelsSettingsView(ai: app.ai) }.environment(\.locale, locale))
        try await capture(
            "skills-page", language: language,
            view: NavigationStack { MobileSkillSettings(skills: app.skills) }.environment(\.locale, locale))
        try await capture(
            "mcp-page", language: language,
            view: NavigationStack { MobileMCPSettings(ai: app.ai, pro: app.pro) }.environment(\.locale, locale))
        try await capture(
            "provider", language: language,
            view: MobileProviderEditor(ai: app.ai, provider: provider).environment(\.locale, locale))
        try await capture(
            "new-provider", language: language,
            view: MobileProviderEditor(ai: app.ai, provider: ModelProvider(name: "")).environment(\.locale, locale))
        try await capture(
            "skill", language: language,
            view: MobileSkillEditor(library: app.skills, skill: skill).environment(\.locale, locale))
        try await capture(
            "mcp", language: language,
            view: NavigationStack { MobileMCPEditor(ai: app.ai, pro: app.pro, server: server) }
                .environment(\.locale, locale))
        let discovery = MobileModelDiscovery(fetch: { _, _ in
            var compact = AIModel(id: "compact-chat")
            compact.displayName = "Compact Chat"
            var candidate = AIModel(id: "research-chat-pro-2026-09")
            candidate.displayName = "Research Chat Pro"
            return [compact, candidate, AIModel(id: "gateway-model-42")]
        })
        try await capture(
            "fetch", language: language,
            view: MobileProviderEditor(ai: app.ai, provider: provider)
                .sheet(isPresented: .constant(true)) {
                    MobileModelFetchSheet(
                        discovery: discovery, existing: ["compact-chat"],
                        fetch: {
                            discovery.start(provider: provider, secret: "")
                        }, add: { _ in }
                    ).environment(\.locale, locale)
                }.environment(\.locale, locale))
        try await capture(
            "add", language: language,
            view: MobileProviderEditor(ai: app.ai, provider: provider)
                .sheet(isPresented: .constant(true)) {
                    MobileAddModelSheet(existing: [], add: { _ in }).environment(\.locale, locale)
                }.environment(\.locale, locale))
        try await capture(
            "host-modal", language: language,
            view: NavigationStack { MobileAISettingsView(app: app) }
                .sheet(isPresented: .constant(true)) {
                    MobileHostEditor(app: app, host: Host(name: "Example", host: "example.invalid"))
                        .environment(\.locale, locale)
                }.environment(\.locale, locale))
        try await capture(
            "pro-modal", language: language,
            view: NavigationStack { MobileAISettingsView(app: app) }
                .sheet(isPresented: .constant(true)) {
                    MobileProView(pro: app.pro).environment(\.locale, locale)
                }.environment(\.locale, locale))
        try await capture(
            "model", language: language,
            view: MobileModelEditorSheet(model: model, provider: provider, save: { _ in })
                .environment(\.locale, locale))
        try await capture(
            "model-automatic-reasoning", language: language,
            view: MobileModelEditorSheet(model: model, provider: provider, save: { _ in })
                .environment(\.locale, locale), scrollToBottom: true)
        var customReasoningModel = model
        customReasoningModel.reasoningProfile = ReasoningProfile(levels: [
            .off: ReasoningLevelMapping(isSupported: false, wireValue: "none"),
            .minimal: ReasoningLevelMapping(isSupported: true),
            .low: ReasoningLevelMapping(isSupported: true, wireValue: "low"),
            .medium: ReasoningLevelMapping(isSupported: true, wireValue: "balanced"),
            .high: ReasoningLevelMapping(isSupported: false),
        ])
        try await capture(
            "model-custom-reasoning", language: language,
            view: MobileModelEditorSheet(model: customReasoningModel, provider: provider, save: { _ in })
                .environment(\.locale, locale), scrollToBottom: true)
        try await capture(
            "model-custom-reasoning-large-type", language: language,
            view: MobileModelEditorSheet(model: customReasoningModel, provider: provider, save: { _ in })
                .environment(\.locale, locale).environment(\.dynamicTypeSize, .accessibility3), scrollToBottom: true)
        try await capture(
            "large-type", language: language,
            view: MobileProviderEditor(ai: app.ai, provider: provider)
                .environment(\.locale, locale).environment(\.dynamicTypeSize, .accessibility3))
        try await capture(
            "empty", language: language,
            view: NavigationStack {
                MobileAISettingsView(app: try! MobileAppModel(inMemory: true))
            }.environment(\.locale, locale))
        let empty = try MobileAppModel(inMemory: true)
        try await capture(
            "empty-models", language: language,
            view: NavigationStack { MobileModelsSettingsView(ai: AIConfigurationModel()) }.environment(\.locale, locale)
        )
        try await capture(
            "empty-skills", language: language,
            view: NavigationStack { MobileSkillSettings(skills: SkillLibraryModel()) }.environment(\.locale, locale))
        try await capture(
            "empty-mcp", language: language,
            view: NavigationStack { MobileMCPSettings(ai: AIConfigurationModel(), pro: empty.pro) }.environment(
                \.locale, locale)
        )
    }

    private func capture<V: View>(
        _ name: String,
        language: String,
        view: V,
        scrollToBottom: Bool = false
    ) async throws {
        if let filter = ProcessInfo.processInfo.environment["TERMIND_AI_SCREENSHOT_NAMES"],
            !filter.split(separator: ",").contains(Substring(name))
        {
            return
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        if name == "provider-direct-key" {
            let field = try #require(
                firstSubview(of: UITextField.self, in: controller.view, matching: { $0.isSecureTextEntry }))
            #expect(field.text == "fixture-api-key")
            #expect(field.isEnabled)
        }
        if scrollToBottom, let scrollView = firstSubview(of: UIScrollView.self, in: controller.view) {
            let offset = max(
                -scrollView.adjustedContentInset.top,
                scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offset), animated: false)
            scrollView.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
        }
        if UIDevice.current.userInterfaceIdiom == .pad, ["fetch", "host-modal", "pro-modal"].contains(name) {
            let presented = try #require(controller.presentedViewController)
            let frame = presented.view.convert(presented.view.bounds, to: window)
            print("AI settings modal geometry: \(name) \(frame) in \(window.bounds)")
            #expect(abs(frame.midX - window.bounds.midX) < 8)
            #expect(abs(frame.midY - window.bounds.midY) < 8)
        }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        #expect(data.count > 10000)
        let directory = FileManager.default.temporaryDirectory.appending(path: "ai-settings-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        if ["provider-hints", "provider-vertex"].contains(name) {
            Attachment.record([UInt8](data), named: "\(device)-\(language)-\(name).png")
        }
        try data.write(to: directory.appending(path: "\(device)-\(language)-\(name).png"))
        print("AI settings snapshot: \(directory.path)/\(device)-\(language)-\(name).png")
    }

    private func firstSubview<T: UIView>(of type: T.Type, in view: UIView, matching: (T) -> Bool = { _ in true }) -> T?
    {
        if let match = view as? T, matching(match) { return match }
        for subview in view.subviews {
            if let match = firstSubview(of: type, in: subview, matching: matching) { return match }
        }
        return nil
    }
}
