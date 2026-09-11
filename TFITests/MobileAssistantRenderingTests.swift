import AgentKit
import Foundation
import SwiftUI
import TermindApplication
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileAssistantRenderingTests {
    @Test func renderNativeAssistantAndArchive() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1" else { return }
        for language in ["en", "zh-Hans"] {
            let app = try MobileAppModel(inMemory: true)
            let conversation = ConversationModel.demo(language: language == "en" ? .english : .simplifiedChineseChina)
            app.assistant.library.insertAndSelect(conversation)
            conversation.composer.draft = language == "en" ? "Check the service logs first." : "先检查服务日志。"
            conversation.attach(ContextChip(kind: .file, label: "service.log", content: "Example log"))
            conversation.isPlanning = true
            try await capture(
                "chat", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
            conversation.composer.draft = "/"
            try await capture(
                "slash", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
            conversation.composer.draft = "/skill "
            try await capture(
                "slash-options", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
            conversation.archivedAt = .now
            conversation.isPinned = false
            try await capture(
                "archive", language: language,
                view: NavigationStack {
                    MobileAssistantLibrary(model: app.assistant, archived: true, selected: {}).navigationTitle(
                        "Archived")
                }.environment(\.locale, Locale(identifier: language)))
            try await capture(
                "archived-chat", language: language,
                view: NavigationStack {
                    MobileAssistantConversation(app: app, model: app.assistant, conversation: conversation)
                        .navigationTitle("Assistant")
                }.environment(\.locale, Locale(identifier: language)))
            app.assistant.newConversation()
            try await capture(
                "empty", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
        }
    }

    private func capture<V: View>(_ name: String, language: String, view: V) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.windowLevel = .alert + 2
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        #expect(data.count > 10000)
        let directory = FileManager.default.temporaryDirectory.appending(path: "assistant-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let url = directory.appending(path: "\(device)-\(language)-\(name).png")
        try data.write(to: url)
        print("Assistant snapshot: \(url.path)")
    }
}
