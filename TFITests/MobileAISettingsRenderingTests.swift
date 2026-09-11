import AgentKit
import Foundation
import SwiftUI
import TermindApplication
import Testing
import UIKit

import struct TermindDomain.Host

@testable import TermindIOS

/// Opt-in native snapshots: set TERMIND_AI_SCREENSHOTS in the test runner environment.
/// Uses the shipping views and a disposable in-memory app, without accounts or network requests.
@Suite(.serialized) @MainActor
struct MobileAISettingsRenderingTests {
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
        let server = MCPServer(name: "Documentation", url: "https://example.invalid/mcp", tools: [tool])
        app.ai.upsert(server)
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
            view: MobileMCPEditor(ai: app.ai, pro: app.pro, server: server).environment(\.locale, locale))
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

    private func capture<V: View>(_ name: String, language: String, view: V) async throws {
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
        try data.write(to: directory.appending(path: "\(device)-\(language)-\(name).png"))
        print("AI settings snapshot: \(directory.path)/\(device)-\(language)-\(name).png")
    }
}
