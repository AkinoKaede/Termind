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
    @Test func shortUserInputUsesItsNaturalHeightAndLongInputUsesAvailableHeight() throws {
        let availableHeight: CGFloat = 640
        let shortApp = try MobileAppModel(inMemory: true)
        let shortAssistant = shortApp.assistant.makeSceneModel()
        shortAssistant.conversation.present(
            AgentUserInputRequest(questions: [
                AgentUserQuestion(id: "answer", header: "Answer", prompt: "Continue?", kind: .text)
            ]))
        let shortHeight = measuredInteractionHeight(
            conversation: shortAssistant.conversation,
            hosts: shortApp.library,
            availableHeight: availableHeight
        )

        let longApp = try MobileAppModel(inMemory: true)
        let longAssistant = longApp.assistant.makeSceneModel()
        let options = (0..<16).map { index in
            AgentUserInputOption(
                id: "option-\(index)",
                label: "Option \(index)",
                detail: "A deliberately detailed explanation that makes this option require another line."
            )
        }
        longAssistant.conversation.present(
            AgentUserInputRequest(questions: [
                AgentUserQuestion(
                    id: "choice",
                    header: "Choose",
                    prompt: "Select an option.",
                    kind: .choice(AgentUserInputChoice(options: options))
                )
            ]))
        let longHeight = measuredInteractionHeight(
            conversation: longAssistant.conversation,
            hosts: longApp.library,
            availableHeight: availableHeight
        )

        #expect(shortHeight > 0)
        #expect(shortHeight < 300)
        #expect(abs(longHeight - availableHeight) < 0.5)
        #expect(shortHeight < longHeight)
    }

    @Test func longApprovalUsesAvailableHeightInsteadOfAFixedCap() async throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
        let conversation = assistant.conversation
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
                approvalPolicy: .ask
            ),
            userIntent: "Update the requested data",
            localReasons: (0..<8).map { "Reason \($0) requires confirmation." }
        )
        let approval = Task { await conversation.requestApproval(request) }
        await Task.yield()

        let availableHeight: CGFloat = 640
        let height = measuredInteractionHeight(
            conversation: conversation,
            hosts: app.library,
            availableHeight: availableHeight
        )

        #expect(abs(height - availableHeight) < 0.5)
        conversation.respondToApproval(request.id, allow: false)
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
        let model = app.assistant.makeSceneModel()
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
        let assistant = app.assistant.makeSceneModel()
        assistant.conversation.composer.draft = "discard this explicit new-chat draft"

        assistant.newConversation()

        #expect(assistant.conversation.isEmpty)
        #expect(assistant.conversation.composer.draft.isEmpty)
    }

    @Test func firstNewConversationSendPromotesDraftAndStartsRun() throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
        let draft = assistant.conversation
        draft.composer.draft = "Why is the service unavailable?"

        assistant.send()

        #expect(assistant.library.selectedConversation === draft)
        #expect(assistant.library.conversations.map(\.id) == [draft.id])
        #expect(assistant.library.draftConversation !== draft)
        #expect(draft.composer.draft.isEmpty)
        #expect(draft.messages.map(\.role) == [.user])
        #expect(draft.messages.first?.text == "Why is the service unavailable?")
        #expect(draft.transcript.map(\.role) == [.user])
        try expectMissingModelFailure(in: draft)
    }

    @Test func attachmentOnlyFirstSendPromotesTheConversation() throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
        let draft = assistant.conversation
        draft.attach(ContextChip(kind: .file, label: "service.log", content: "connection refused"))

        assistant.send()

        #expect(assistant.library.selectedConversation === draft)
        #expect(assistant.library.conversations.map(\.id) == [draft.id])
        #expect(draft.messages.map(\.role) == [.user])
        #expect(draft.messages.first?.text.isEmpty == true)
        #expect(draft.messages.first?.contextChips.map(\.label) == ["service.log"])
        #expect(draft.transcript.first?.text.contains("connection refused") == true)
        try expectMissingModelFailure(in: draft)
    }

    @Test func existingConversationSendStillUsesTheDraftExecutionPath() async throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
        let conversation = ConversationModel()
        conversation.composer.draft = "Opening question"
        _ = assistant.library.startConversation(conversation)
        conversation.composer.draft = "Follow-up question"

        assistant.send()

        #expect(conversation.composer.draft.isEmpty)
        #expect(conversation.messages.map(\.text).contains("Follow-up question"))
        #expect(await eventually { conversation.runState == .failed })
        #expect(conversation.messages.map(\.role) == [.user, .user])
        #expect(conversation.transcript.map(\.role) == [.user, .user])
        try expectMissingModelFailure(in: conversation)
    }

    @Test func slashCatalogShowsAlphabetizedCompactPlanAndSkillCommandsOnMobile() throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
        let conversation = ConversationModel(messages: [ChatMessage(role: .user, text: "Inspect")])
        assistant.library.insertAndSelect(conversation)
        let composer = MobileAssistantComposer(pro: app.pro, model: assistant, conversation: conversation)
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
        #expect(commands.allSatisfy { $0.platforms.contains(.mobile) })
        #expect(!first.summary.isEmpty)
    }

    @Test func selectingAnExplicitModelRemembersItAndClampsEffort() throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
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

        assistant.conversation.reasoningEffort = .low
        let reasoningRef = AIModelRef(modelProviderID: provider.id, modelID: reasoning.id)
        assistant.selectModel(reasoningRef)
        #expect(assistant.conversation.model == reasoningRef)
        #expect(app.ai.lastSelectedModel == reasoningRef)
        #expect(assistant.conversation.reasoningEffort == .high)

        let plainRef = AIModelRef(modelProviderID: provider.id, modelID: plain.id)
        assistant.selectModel(plainRef)
        #expect(assistant.conversation.reasoningEffort == .off)
    }

    @Test func assistantDropImporterAcceptsFileURLsAndImageData() async throws {
        let app = try MobileAppModel(inMemory: true)
        let conversation = app.assistant.makeSceneModel().conversation
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
        func registry(_ model: AIModel, includesTerminalSuggestion: Bool = false) -> AgentToolRegistry {
            AssistantToolRegistry.make(
                conversation: conversation, model: model, provider: provider,
                skills: app.skills.catalog, channel: channel, ai: app.ai, hosts: hosts, metrics: app.metrics.core,
                connections: connections, authentication: authentication, background: background,
                includesTerminalSuggestion: includesTerminalSuggestion)
        }
        let mobileDescriptors = registry(model).descriptors
        let names = Set(mobileDescriptors.map(\.name))
        for name in [
            "ssh_exec", "ssh_wait", "sftp_read", "sftp_write", "list_hosts", "get_metrics",
            "scratch_pull", "scratch_push", "present_plan", "manage_tasks", "request_user_input", "request_user_secret",
            "terminal_suggest",
        ] {
            #expect(names.contains(name), "Missing tool: \(name)")
        }
        // Surface availability is enforced at execution, not by changing the cached tool definitions.
        #expect(mobileDescriptors == registry(model, includesTerminalSuggestion: true).descriptors)
        let exec = try #require(mobileDescriptors.first { $0.name == "ssh_exec" })
        #expect(exec.summary.contains("discover host_id with list_hosts"))
        #expect(exec.summary.contains("do not call request_user_secret for SSH login"))
        try AgentJSONSchemaValidator.validate(
            .object(["host_id": .string(UUID().uuidString), "command": .string("uname -a")]),
            against: exec.inputSchema
        )
        model.abilities = []
        #expect(registry(model).descriptors.isEmpty)
        #expect(registry(model, includesTerminalSuggestion: true).descriptors.isEmpty)
    }

    @Test func backgroundExpirationBlocksNewRunsUntilCleanupCompletes() async throws {
        let app = try MobileAppModel(inMemory: true)
        let assistant = app.assistant.makeSceneModel()
        assistant.conversation.composer.draft = "preserve"
        app.assistant.expireBackground()
        #expect(app.assistant.isSuspending)
        assistant.send()
        #expect(assistant.conversation.composer.draft == "preserve")
        await app.assistant.waitForSuspension()
        #expect(!app.assistant.isSuspending)
        #expect(!app.assistant.isRunning)
    }

    private func measuredInteractionHeight(
        conversation: ConversationModel,
        hosts: HostLibraryModel,
        width: CGFloat = 390,
        availableHeight: CGFloat = 1_000
    ) -> CGFloat {
        let controller = UIHostingController(
            rootView: MobileAssistantInteraction(conversation: conversation, hosts: hosts)
                .environment(\.dynamicTypeSize, .large)
        )
        return controller.sizeThatFits(in: CGSize(width: width, height: availableHeight)).height
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@MainActor
private func expectMissingModelFailure(in conversation: ConversationModel) throws {
    // In-memory apps have no Chat model. That must produce a failure row, not an authored answer.
    #expect(conversation.runState == .failed)
    #expect(conversation.runSummaries.count == 1)
    let run = try #require(conversation.runSummaries.values.first)
    #expect(run.state == .failed)
    #expect(run.finishedAt != nil)
    let reason = try #require(run.failure)
    #expect(!reason.isEmpty)
    let prompt = try #require(conversation.transcript.last)
    #expect(conversation.messageRunIDs[prompt.id] == run.id)
    let failures = conversation.timeline.compactMap { item -> AgentRunFailureNotice? in
        guard case .failure(let failure) = item else { return nil }
        return failure
    }
    #expect(failures.count == 1)
    #expect(failures.first?.runID == run.id)
    #expect(failures.first?.reason == reason)
    #expect(AssistantExecutionController.titleContext(for: conversation) == nil)
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
