import AVFoundation
import AgentKit
import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import TermindIOS

@Suite @MainActor
struct MobileAssistantTests {
    @Test func shortUserInputUsesItsNaturalHeightAndLongInputUsesTheCap() throws {
        let shortApp = try MobileAppModel(inMemory: true)
        shortApp.assistant.conversation.present(
            AgentUserInputRequest(questions: [
                AgentUserQuestion(id: "answer", header: "Answer", prompt: "Continue?", kind: .text)
            ]))
        let shortHeight = measuredInteractionHeight(
            conversation: shortApp.assistant.conversation,
            hosts: shortApp.library
        )

        let longApp = try MobileAppModel(inMemory: true)
        let options = (0..<16).map { index in
            AgentUserInputOption(
                id: "option-\(index)",
                label: "Option \(index)",
                detail: "A deliberately detailed explanation that makes this option require another line."
            )
        }
        longApp.assistant.conversation.present(
            AgentUserInputRequest(questions: [
                AgentUserQuestion(
                    id: "choice",
                    header: "Choose",
                    prompt: "Select an option.",
                    kind: .choice(AgentUserInputChoice(options: options))
                )
            ]))
        let longHeight = measuredInteractionHeight(
            conversation: longApp.assistant.conversation,
            hosts: longApp.library
        )

        #expect(shortHeight > 0)
        #expect(shortHeight < 300)
        #expect(abs(longHeight - 300) < 0.5)
        #expect(shortHeight < longHeight)
    }

    @Test func longApprovalUsesTheSameHeightCap() async throws {
        let app = try MobileAppModel(inMemory: true)
        let conversation = app.assistant.conversation
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(
                id: "approval",
                name: "write",
                arguments: .object(
                    Dictionary(
                        uniqueKeysWithValues: (0..<20).map { index in
                            ("argument-\(index)", AgentJSONValue.string(String(repeating: "value ", count: 12)))
                        })
                )
            )
        )
        let request = AgentApprovalRequest(
            invocation: invocation,
            descriptor: AgentToolDescriptor(
                name: "write",
                summary: "Write data",
                inputSchema: .object([:]),
                target: .local,
                safety: .requiresAuthorization
            ),
            userIntent: "Update the requested data",
            localReasons: (0..<8).map { "Reason \($0) requires confirmation." }
        )
        let approval = Task { await conversation.requestApproval(request) }
        await Task.yield()

        let height = measuredInteractionHeight(conversation: conversation, hosts: app.library)

        #expect(abs(height - 300) < 0.5)
        conversation.respondToApproval(allow: false)
        if case .deny = await approval.value {
        } else {
            Issue.record("Expected the approval request to be denied during cleanup")
        }
    }

    @Test func speechTapHandlerRunsOnTheRealtimeQueueWithoutActorIsolation() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData?[0][0] = 0.25
        let probe = SpeechTapProbe()
        let invocation = SpeechTapInvocation(
            buffer: buffer,
            handler: IOSSpeechAudioInput.makeTapHandler(
                bufferHandler: { _ in probe.recordBuffer() },
                levelHandler: { probe.recordLevel($0) }
            )
        )

        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                invocation.handler(invocation.buffer, AVAudioTime(hostTime: 0))
                continuation.resume()
            }
        }

        #expect(probe.snapshot().buffers == 1)
        #expect(probe.snapshot().level > 0)
    }

    @Test func sharedTranscriptProjectionKeepsStableKindsAndEditCapabilities() {
        let user = ChatMessage(role: .user, text: "Inspect")
        let assistant = ChatMessage(role: .assistant, text: "Done")
        let entries = AssistantTranscriptEntry.items(
            timeline: [.message(user), .message(assistant)],
            isInterrupted: true,
            canEdit: { $0 == user.id },
            canFork: { $0 == assistant.id }
        )

        #expect(entries.map(\.kind) == [.user, .assistant, .interrupted])
        if case .user(_, let canEdit) = entries[0].content { #expect(canEdit) } else { Issue.record("Missing user") }
        if case .assistant(_, let canFork) = entries[1].content {
            #expect(canFork)
        } else {
            Issue.record("Missing assistant")
        }
    }

    @Test func changingConversationsPreservesTheirDraftsAndArchiveNavigation() async throws {
        let app = try MobileAppModel(inMemory: true)
        let model = app.assistant
        let first = ConversationModel(messages: [ChatMessage(role: .user, text: "First")])
        let second = ConversationModel(messages: [ChatMessage(role: .user, text: "Second")])
        model.library.insertAndSelect(first)
        first.composer.draft = "first draft"
        model.library.insertAndSelect(second)
        second.composer.draft = "second draft"
        model.select(first)
        #expect(model.conversation.composer.draft == "first draft")
        model.select(second)
        #expect(model.conversation.composer.draft == "second draft")
        #expect(first.composer.draft == "first draft")
    }

    @Test func explicitNewConversationStartsWithAFreshDraft() throws {
        let app = try MobileAppModel(inMemory: true)
        app.assistant.conversation.composer.draft = "discard this explicit new-chat draft"

        app.assistant.newConversation()

        #expect(app.assistant.conversation.isEmpty)
        #expect(app.assistant.conversation.composer.draft.isEmpty)
    }

    @Test func firstNewConversationSendPromotesDraftAndStartsRun() throws {
        let app = try MobileAppModel(inMemory: true)
        let draft = app.assistant.conversation
        draft.composer.draft = "Why is the service unavailable?"

        app.assistant.send()

        #expect(app.assistant.library.selectedConversation === draft)
        #expect(app.assistant.library.conversations.map(\.id) == [draft.id])
        #expect(app.assistant.library.draftConversation !== draft)
        #expect(draft.composer.draft.isEmpty)
        #expect(draft.messages.map(\.role) == [.user, .assistant])
        #expect(draft.messages.first?.text == "Why is the service unavailable?")
        #expect(draft.transcript.map(\.role) == [.user])
    }

    @Test func attachmentOnlyFirstSendPromotesTheConversation() throws {
        let app = try MobileAppModel(inMemory: true)
        let draft = app.assistant.conversation
        draft.attach(ContextChip(kind: .file, label: "service.log", content: "connection refused"))

        app.assistant.send()

        #expect(app.assistant.library.selectedConversation === draft)
        #expect(app.assistant.library.conversations.map(\.id) == [draft.id])
        #expect(draft.messages.map(\.role) == [.user, .assistant])
        #expect(draft.messages.first?.text.isEmpty == true)
        #expect(draft.messages.first?.contextChips.map(\.label) == ["service.log"])
        #expect(draft.transcript.first?.text.contains("connection refused") == true)
    }

    @Test func existingConversationSendStillUsesTheDraftExecutionPath() async throws {
        let app = try MobileAppModel(inMemory: true)
        let conversation = ConversationModel()
        conversation.composer.draft = "Opening question"
        _ = app.assistant.library.startConversation(conversation)
        conversation.composer.draft = "Follow-up question"

        app.assistant.send()

        #expect(conversation.composer.draft.isEmpty)
        #expect(conversation.messages.map(\.text).contains("Follow-up question"))
        for _ in 0..<20 {
            if conversation.messages.last?.role == .assistant { break }
            await Task.yield()
        }
        #expect(conversation.messages.map(\.role) == [.user, .user, .assistant])
        #expect(conversation.transcript.map(\.role) == [.user, .user])
    }

    @Test func slashCatalogShowsAlphabetizedCompactPlanAndSkillCommandsOnMobile() throws {
        let app = try MobileAppModel(inMemory: true)
        let conversation = ConversationModel(messages: [ChatMessage(role: .user, text: "Inspect")])
        app.assistant.library.insertAndSelect(conversation)
        let composer = MobileAssistantComposer(pro: app.pro, model: app.assistant, conversation: conversation)
        let commands = composer.availableCommands
        let first = try #require(commands.first)
        #expect(commands.contains { $0.id == "plan" })
        #expect(commands.contains { $0.id == "compact" })
        #expect(Set(commands.map(\.id)).isSubset(of: Set(["compact", "plan", "skill"])))
        #expect(
            commands.map(\.displayName)
                == commands.map(\.displayName).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
        )
        #expect(!commands.contains { !$0.isShownOnMobile })
        #expect(!first.summary.isEmpty)
    }

    @Test func selectingAnExplicitModelRemembersItAndClampsEffort() throws {
        let app = try MobileAppModel(inMemory: true)
        var reasoning = AIModel(id: "reasoning-model")
        reasoning.abilities.insert(.reasoning)
        reasoning.reasoningProfile = ReasoningProfile(levels: [
            .off: ReasoningLevelMapping(isSupported: true),
            .high: ReasoningLevelMapping(isSupported: true),
        ])
        var plain = AIModel(id: "plain-model")
        plain.reasoningProfile = ReasoningProfile(levels: [
            .off: ReasoningLevelMapping(isSupported: true)
        ])
        let provider = ModelProvider(name: "Test", models: [reasoning, plain])
        app.ai.upsert(provider)

        app.assistant.conversation.reasoningEffort = .low
        let reasoningRef = AIModelRef(modelProviderID: provider.id, modelID: reasoning.id)
        app.assistant.selectModel(reasoningRef)
        #expect(app.assistant.conversation.model == reasoningRef)
        #expect(app.ai.lastSelectedModel == reasoningRef)
        #expect(app.assistant.conversation.reasoningEffort == .high)

        let plainRef = AIModelRef(modelProviderID: provider.id, modelID: plain.id)
        app.assistant.selectModel(plainRef)
        #expect(app.assistant.conversation.reasoningEffort == .off)
    }

    @Test func assistantDropImporterAcceptsFileURLsAndImageData() async throws {
        let app = try MobileAppModel(inMemory: true)
        let conversation = app.assistant.conversation
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "service.log")
        try Data("connection refused".utf8).write(to: file)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let imageData = try #require(image.pngData())

        let fileProvider = try #require(NSItemProvider(contentsOf: file))
        let imageProvider = NSItemProvider(
            item: imageData as NSData,
            typeIdentifier: UTType.png.identifier
        )
        let payload = await MobileDropPayloadLoader.load(
            [fileProvider, imageProvider],
            kinds: [.files, .images],
            fileMode: .staged
        )

        let stagedFile = try #require(payload.fileURLs.first)
        defer {
            if let stagedRoot = payload.stagedRoot {
                try? FileManager.default.removeItem(at: stagedRoot)
            }
        }
        #expect(stagedFile != file)
        #expect(stagedFile.lastPathComponent == file.lastPathComponent)
        #expect(try Data(contentsOf: stagedFile) == Data("connection refused".utf8))
        #expect(payload.images == [imageData])
        #expect(payload.failures.isEmpty)
        conversation.importAttachmentFiles(payload.fileURLs)
        conversation.importAttachmentImages(payload.images, label: String(localized: "Dropped image"))
        #expect(await eventually { conversation.composer.pendingAttachments.isEmpty })
        #expect(Set(conversation.composer.attachments.map(\.label)) == ["service.log", "Dropped image"])
        #expect(
            conversation.composer.attachments.contains {
                $0.label == "service.log" && $0.content == "connection refused"
            }
        )
        #expect(conversation.composer.attachments.contains { $0.image != nil })
    }

    @Test func completeRegistryIncludesRemoteAndBuiltInToolsOnlyForCapableModels() throws {
        let app = try MobileAppModel(inMemory: true)
        let hosts = AgentHostResolver(store: app.library)
        let connections = AgentConnectionPool(
            configuration: { _ in throw CancellationError() },
            routeFingerprint: { _ in "" }, openExec: { _ in throw CancellationError() },
            openSFTP: { _ in throw CancellationError() }, sweepInterval: nil)
        let authentication = AgentSSHAuthenticationRegistry(resolver: hosts)
        let background = AgentBackgroundCommands(sweepInterval: nil)
        let repository = InMemoryAgentRunRepository()
        let channel = AgentEventChannel(repository: repository)
        var model = AIModel(id: "test")
        model.abilities = [.toolCall]
        let provider = ModelProvider(name: "Test")
        let conversation = ConversationModel()
        func registry(_ model: AIModel) -> AgentToolRegistry {
            AssistantToolRegistry.make(
                conversation: conversation, model: model, provider: provider,
                skills: app.skills.catalog, channel: channel, ai: app.ai, hosts: hosts, metrics: app.metrics.core,
                connections: connections, authentication: authentication, background: background)
        }
        let names = Set(registry(model).descriptors.map(\.name))
        for name in [
            "ssh_exec", "ssh_wait", "sftp_read", "sftp_write", "list_hosts", "get_metrics",
            "scratch_pull", "scratch_push", "present_plan", "manage_tasks", "request_user_input", "request_user_secret",
        ] {
            #expect(names.contains(name), "Missing tool: \(name)")
        }
        #expect(!names.contains("terminal_suggest"))
        model.abilities = []
        #expect(registry(model).descriptors.isEmpty)
    }

    @Test func backgroundExpirationBlocksNewRunsUntilCleanupCompletes() async throws {
        let app = try MobileAppModel(inMemory: true)
        app.assistant.conversation.composer.draft = "preserve"
        app.assistant.expireBackground()
        #expect(app.assistant.isSuspending)
        app.assistant.send()
        #expect(app.assistant.conversation.composer.draft == "preserve")
        await app.assistant.waitForSuspension()
        #expect(!app.assistant.isSuspending)
        #expect(!app.assistant.isRunning)
    }

    private func measuredInteractionHeight(
        conversation: ConversationModel,
        hosts: HostLibraryModel,
        width: CGFloat = 390
    ) -> CGFloat {
        let controller = UIHostingController(
            rootView: MobileAssistantInteraction(conversation: conversation, hosts: hosts)
                .environment(\.dynamicTypeSize, .large)
        )
        return controller.sizeThatFits(in: CGSize(width: width, height: 1_000)).height
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

nonisolated private final class SpeechTapInvocation: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let handler: AVAudioNodeTapBlock

    init(buffer: AVAudioPCMBuffer, handler: @escaping AVAudioNodeTapBlock) {
        self.buffer = buffer
        self.handler = handler
    }
}

nonisolated private final class SpeechTapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var level: Float = 0

    func recordBuffer() {
        lock.withLock { buffers += 1 }
    }

    func recordLevel(_ value: Float) {
        lock.withLock { level = value }
    }

    func snapshot() -> (buffers: Int, level: Float) {
        lock.withLock { (buffers, level) }
    }
}
