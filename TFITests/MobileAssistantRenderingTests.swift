import AgentKit
import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileAssistantRenderingTests {
    @Test func renderUserImageAlignment() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1" else { return }
        let app = try MobileAppModel(inMemory: true)
        let conversation = ConversationModel()
        for index in 0..<7 {
            let size =
                index.isMultiple(of: 2)
                ? CGSize(width: 240, height: 120)
                : CGSize(width: 120, height: 240)
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor(
                    hue: CGFloat(index) / 7,
                    saturation: 0.7,
                    brightness: 0.85,
                    alpha: 1
                ).setFill()
                context.fill(CGRect(origin: .zero, size: size))
            }
            let attachment = AgentImageAttachment(
                label: "preview-\(index).png",
                mimeType: "image/png",
                data: try #require(image.pngData()),
                pixelWidth: Int(size.width),
                pixelHeight: Int(size.height)
            )
            conversation.attach(
                ContextChip(
                    id: attachment.id,
                    kind: .image,
                    label: attachment.label,
                    image: attachment
                )
            )
        }
        conversation.appendUserTurn("Compare these images.")
        app.assistant.library.insertAndSelect(conversation)

        try await capture(
            "user-images",
            language: "en",
            view: NavigationStack {
                MobileAssistantView(app: app, model: app.assistant)
            }
        )
    }

    @Test func renderTranscriptWorkStates() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1" else { return }
        for language in ["en", "zh-Hans"] {
            for phase in AssistantTranscriptPreview.Phase.allCases {
                let group = AssistantTranscriptPreview.work(
                    language: language == "en" ? .english : .simplifiedChinese, phase: phase
                )
                let presentation = AssistantTranscriptPresentationState()
                presentation.followDefault(true, for: .work(group.id))
                for item in group.items {
                    switch item {
                    case .tool(let card):
                        presentation.followDefault(true, for: .tool(card.id))
                    case .tools(let batch):
                        presentation.followDefault(true, for: .toolBatch(batch.id))
                        for card in batch.cards {
                            presentation.followDefault(true, for: .tool(card.id))
                        }
                    case .reasoning, .message:
                        break
                    }
                }
                let row = MobileAssistantWorkRow(
                    group: group, presentation: presentation,
                    hostName: { _ in "Production" }
                )
                for dark in [false, true] {
                    try await capture(
                        "work-\(phase.rawValue)-\(dark ? "dark" : "light")", language: language,
                        view: ScrollView { row.padding(20) }
                            .environment(\.locale, Locale(identifier: language))
                            .environment(\.colorScheme, dark ? .dark : .light)
                    )
                }
                try await capture(
                    "work-\(phase.rawValue)-large-reduced", language: language,
                    view: ScrollView { row.padding(20) }
                        .environment(\.locale, Locale(identifier: language))
                        .environment(\.dynamicTypeSize, .accessibility2)
                        .environment(\.mobileListReduceMotion, true)
                )
            }
        }
    }

    @Test func renderNativeAssistant() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1" else { return }
        for language in ["en", "zh-Hans"] {
            let app = try MobileAppModel(inMemory: true)
            let conversation = ConversationModel.demo(language: language == "en" ? .english : .simplifiedChinese)
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
            conversation.composer.draft = ""
            conversation.beginCompaction()
            try await capture(
                "compact-running", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
            conversation.failCompaction(
                language == "en" ? "The context service is unavailable." : "上下文服务不可用。"
            )
            try await capture(
                "compact-failed", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
            conversation.endCompaction()
            conversation.appendUserTurn(
                language == "en" ? "Preserve the latest service diagnosis." : "保留最新的服务诊断。"
            )
            let compacted = conversation.applyCompaction(
                summary: language == "en" ? "Earlier context summary" : "早期上下文摘要",
                cut: conversation.transcript.count
            )
            #expect(compacted != nil)
            #expect(conversation.timeline.contains { if case .compaction = $0 { true } else { false } })
            try await capture(
                "compact-completed", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
            conversation.composer.attachmentImportError =
                language == "en" ? "The selected attachment could not be imported." : "无法导入所选附件。"
            try await capture(
                "attachment-error", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
            conversation.composer.attachmentImportError = nil
            conversation.handle(
                .tasksUpdated([
                    AgentTask(
                        id: "verify",
                        title: language == "en" ? "Verify the selected approach" : "验证所选方案",
                        status: .inProgress
                    )
                ]))
            conversation.present(
                AgentUserInputRequest(questions: [
                    AgentUserQuestion(
                        id: "deployment",
                        header: language == "en" ? "Deployment" : "部署",
                        prompt: language == "en" ? "Where should this run?" : "应在哪里运行？",
                        kind: .choice(
                            AgentUserInputChoice(options: [
                                AgentUserInputOption(
                                    id: "staging",
                                    label: language == "en" ? "Staging" : "预发布环境",
                                    detail: language == "en" ? "Validate before production." : "上线前先验证。",
                                    isRecommended: true
                                ),
                                AgentUserInputOption(
                                    id: "production",
                                    label: language == "en" ? "Production" : "生产环境",
                                    detail: language == "en"
                                        ? "Apply directly to live traffic." : "直接应用到线上流量。"
                                ),
                            ]))
                    )
                ]))
            try await capture(
                "question", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
            conversation.cancelUserInput()
            conversation.archivedAt = .now
            conversation.isPinned = false
            try await capture(
                "archived-chat", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
            app.assistant.newConversation()
            try await capture(
                "empty", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: app.assistant)
                }.environment(\.locale, Locale(identifier: language)))
        }
    }

    @Test func renderNativeConversationLibraries() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1" else { return }
        for language in ["en", "zh-Hans"] {
            let app = try MobileAppModel(inMemory: true)
            let pinned = ConversationModel.demo(language: language == "en" ? .english : .simplifiedChinese)
            pinned.isPinned = true
            let ordinary = ConversationModel()
            ordinary.customTitle = language == "en" ? "Review deployment logs" : "检查部署日志"
            let streaming = ConversationModel(runState: .running)
            streaming.customTitle = language == "en" ? "Investigate database latency" : "调查数据库延迟"
            app.assistant.library.insertAndSelect(pinned)
            app.assistant.library.insertAndSelect(ordinary)
            app.assistant.library.insertAndSelect(streaming)
            try await capture(
                "conversations", language: language,
                view: NavigationStack {
                    MobileAssistantLibrary(
                        model: app.assistant, route: .conversations,
                        selected: {}, showArchived: {}
                    ).navigationTitle("Conversations")
                }.environment(\.locale, Locale(identifier: language)))
            pinned.archivedAt = .now
            pinned.isPinned = false
            try await capture(
                "archive", language: language,
                view: NavigationStack {
                    MobileAssistantLibrary(
                        model: app.assistant, route: .archived,
                        selected: {}, showArchived: {}
                    ).navigationTitle("Archived")
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
