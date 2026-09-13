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
        let assistant = app.assistant.makeSceneModel()
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
        assistant.library.insertAndSelect(conversation)

        try await capture(
            "user-images",
            language: "en",
            view: NavigationStack {
                MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
            }
        )
    }

    @Test func renderTranscriptWorkStates() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1" else { return }
        for language in ["en", "zh-Hans", "zh-Hant"] {
            for phase in AssistantTranscriptPreview.Phase.allCases {
                let group = AssistantTranscriptPreview.work(
                    language: try #require(AppLanguage(rawValue: language)), phase: phase
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
        for language in ["en", "zh-Hans", "zh-Hant"] {
            func text(_ english: String, _ simplified: String, _ traditional: String) -> String {
                switch language {
                case "zh-Hans": simplified
                case "zh-Hant": traditional
                default: english
                }
            }
            let app = try MobileAppModel(inMemory: true)
            let assistant = app.assistant.makeSceneModel()
            let conversation = ConversationModel.demo(language: try #require(AppLanguage(rawValue: language)))
            assistant.library.insertAndSelect(conversation)
            conversation.composer.draft =
                switch language {
                case "zh-Hans": "先检查服务日志。"
                case "zh-Hant": "先檢查服務日誌。"
                default: "Check the service logs first."
                }
            conversation.attach(ContextChip(kind: .file, label: "service.log", content: "Example log"))
            conversation.isPlanning = true
            try await capture(
                "chat", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            conversation.composer.draft = "/"
            try await capture(
                "slash", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            conversation.composer.draft = "/skill "
            try await capture(
                "slash-options", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            conversation.composer.draft = ""
            conversation.beginCompaction()
            try await capture(
                "compact-running", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            conversation.failCompaction(
                text("The context service is unavailable.", "上下文服务不可用。", "上下文服務目前無法使用。")
            )
            try await capture(
                "compact-failed", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            conversation.endCompaction()
            conversation.appendUserTurn(
                text("Preserve the latest service diagnosis.", "保留最新的服务诊断。", "保留最新的服務診斷。")
            )
            let compacted = conversation.applyCompaction(
                summary: text("Earlier context summary", "早期上下文摘要", "先前的上下文摘要"),
                cut: conversation.transcript.count
            )
            #expect(compacted != nil)
            #expect(conversation.timeline.contains { if case .compaction = $0 { true } else { false } })
            try await capture(
                "compact-completed", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            conversation.composer.attachmentImportError = text(
                "The selected attachment could not be imported.", "无法导入所选附件。", "無法匯入所選附件。")
            try await capture(
                "attachment-error", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            conversation.composer.attachmentImportError = nil
            conversation.handle(
                .tasksUpdated([
                    AgentTask(
                        id: "verify",
                        title: text("Verify the selected approach", "验证所选方案", "驗證所選方案"),
                        status: .inProgress
                    )
                ]))
            conversation.present(
                AgentUserInputRequest(questions: [
                    AgentUserQuestion(
                        id: "deployment",
                        header: text("Deployment", "部署", "部署"),
                        prompt: text("Where should this run?", "应在哪里运行？", "應在哪裡執行？"),
                        kind: .choice(
                            AgentUserInputChoice(options: [
                                AgentUserInputOption(
                                    id: "staging",
                                    label: text("Staging", "预发布环境", "測試環境"),
                                    detail: text(
                                        "Validate before production.", "上线前先验证。", "上線前先進行驗證。"),
                                    isRecommended: true
                                ),
                                AgentUserInputOption(
                                    id: "production",
                                    label: text("Production", "生产环境", "正式環境"),
                                    detail: text(
                                        "Apply directly to live traffic.", "直接应用到线上流量。", "直接套用至正式流量。")
                                ),
                            ]))
                    )
                ]))
            try await capture(
                "question", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            try await capture(
                "question-dark", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }
                .environment(\.locale, Locale(identifier: language))
                .preferredColorScheme(.dark))
            conversation.setUserInputCustomAnswer(
                text("A private canary", "私有金丝雀环境", "私有的金絲雀環境"),
                for: "deployment"
            )
            try await capture(
                "question-custom", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            conversation.cancelUserInput()
            conversation.present(
                AgentUserInputRequest(questions: [
                    AgentUserQuestion(
                        id: "checks",
                        header: text("Verification", "验证", "驗證"),
                        prompt: text("Which checks should run?", "应该运行哪些检查？", "應執行哪些檢查？"),
                        kind: .choice(
                            AgentUserInputChoice(
                                options: [
                                    AgentUserInputOption(
                                        id: "smoke",
                                        label: text("Smoke tests", "冒烟测试", "冒煙測試"),
                                        detail: text(
                                            "Verify the critical path.", "验证关键路径。", "驗證關鍵路徑。"),
                                        isRecommended: true
                                    ),
                                    AgentUserInputOption(
                                        id: "load",
                                        label: text("Load tests", "负载测试", "負載測試"),
                                        detail: text(
                                            "Exercise expected peak traffic.", "模拟预期峰值流量。", "模擬預期尖峰流量。")
                                    ),
                                ],
                                allowsMultipleAnswers: true,
                                customPlaceholder: text("Another check…", "其他检查…", "其他檢查…")
                            )
                        )
                    )
                ]))
            conversation.toggleUserInputOption("smoke", in: "checks")
            try await capture(
                "question-multiple", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            try await capture(
                "question-multiple-large", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, .accessibility2))
            conversation.cancelUserInput()
            conversation.present(
                AgentUserInputRequest(questions: [
                    AgentUserQuestion(
                        id: "secret",
                        header: text("Authentication", "身份验证", "身分驗證"),
                        prompt: text("Enter the one-time secret.", "输入一次性机密。", "輸入一次性機密資訊。"),
                        kind: .secret
                    )
                ]))
            conversation.secretInputDraft = "rendering-secret"
            try await capture(
                "question-secret", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            try await capture(
                "question-secret-dark", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }
                .environment(\.locale, Locale(identifier: language))
                .preferredColorScheme(.dark))
            conversation.cancelUserInput()
            conversation.archivedAt = .now
            conversation.isPinned = false
            try await capture(
                "archived-chat", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
            assistant.newConversation()
            try await capture(
                "empty", language: language,
                view: NavigationStack {
                    MobileAssistantView(app: app, model: assistant, libraryRoute: .constant(nil))
                }.environment(\.locale, Locale(identifier: language)))
        }
    }

    @Test func renderNativeConversationLibraries() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1" else { return }
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let app = try MobileAppModel(inMemory: true)
            let assistant = app.assistant.makeSceneModel()
            let pinned = ConversationModel.demo(language: try #require(AppLanguage(rawValue: language)))
            pinned.isPinned = true
            let ordinary = ConversationModel()
            ordinary.customTitle =
                switch language {
                case "zh-Hans": "检查部署日志"
                case "zh-Hant": "檢查部署日誌"
                default: "Review deployment logs"
                }
            let streaming = ConversationModel(runState: .running)
            streaming.customTitle =
                switch language {
                case "zh-Hans": "调查数据库延迟"
                case "zh-Hant": "調查資料庫延遲"
                default: "Investigate database latency"
                }
            assistant.library.insertAndSelect(pinned)
            assistant.library.insertAndSelect(ordinary)
            assistant.library.insertAndSelect(streaming)
            try await capture(
                "conversations", language: language,
                view: NavigationStack {
                    MobileAssistantLibrary(
                        model: assistant, route: .conversations,
                        selected: {}, showArchived: {}
                    ).navigationTitle("Conversations")
                }.environment(\.locale, Locale(identifier: language)))
            pinned.archivedAt = .now
            pinned.isPinned = false
            try await capture(
                "archive", language: language,
                view: NavigationStack {
                    MobileAssistantLibrary(
                        model: assistant, route: .archived,
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
