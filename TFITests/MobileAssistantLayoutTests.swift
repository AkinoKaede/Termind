// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import ListViewKit
import SwiftUI
import TermindApplication
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileAssistantLayoutTests {
    @Test(.requiresKeyWindow, arguments: [true, false], [true, false])
    func approvalRoundTripRetainsTranscriptAndScrollPosition(allow: Bool, atBottom: Bool) async throws {
        let app = try MobileAppModel(inMemory: true)
        let model = makeConversation(in: app)
        let conversation = model.conversation
        let request = AgentApprovalRequest(
            invocation: AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(id: "approval", name: "write", arguments: .object(["path": .string("file.txt")]))
            ),
            descriptor: AgentToolDescriptor(
                name: "write", summary: "Write data", inputSchema: .object([:]), target: .local, approvalPolicy: .ask
            ),
            userIntent: "Update the requested data", localReasons: ["Confirm writing the file."]
        )
        conversation.handle(.toolProposed(request.invocation, request.descriptor))
        try await withConversation(app: app, model: model) { controller in
            let list = try transcript(in: controller)
            list.setContentOffset(atBottom ? list.maximumContentOffset : CGPoint(x: 0, y: 500), animated: false)
            await settle(controller)
            if atBottom { list.setContentOffset(list.maximumContentOffset, animated: false) }
            list.layoutIfNeeded()
            let originalOffset = list.contentOffset.y
            let originalHeight = list.bounds.height
            let originalContentHeight = list.contentSize.height
            let approval = Task { await conversation.requestApproval(request) }
            defer { conversation.respondToApproval(request.id, allow: false) }
            await settle(controller)
            #expect(conversation.pendingApproval?.id == request.id)
            let pendingList = try transcript(in: controller)
            #expect(ObjectIdentifier(pendingList) == ObjectIdentifier(list))
            #expect(pendingList.bounds.height < originalHeight)
            checkScroll(pendingList, atBottom: atBottom, originalOffset: originalOffset)
            #expect(abs(pendingList.contentSize.height - originalContentHeight) < 1)

            conversation.respondToApproval(request.id, allow: allow)
            _ = await approval.value
            await settle(controller)
            #expect(conversation.pendingApproval == nil)
            let completedList = try transcript(in: controller)
            #expect(ObjectIdentifier(completedList) == ObjectIdentifier(list))
            #expect(abs(completedList.bounds.height - originalHeight) < 1)
            #expect(abs(completedList.contentSize.height - originalContentHeight) < 1)
            checkScroll(completedList, atBottom: atBottom, originalOffset: originalOffset)
        }
    }

    @Test(.requiresKeyWindow, arguments: [true, false])
    func userInputRoundTripRetainsTranscriptWhileReadingHistory(submit: Bool) async throws {
        let app = try MobileAppModel(inMemory: true)
        let model = makeConversation(in: app)
        let conversation = model.conversation
        try await withConversation(app: app, model: model) { controller in
            let list = try transcript(in: controller)
            list.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
            await settle(controller)
            list.layoutIfNeeded()
            let originalOffset = list.contentOffset.y
            let originalHeight = list.bounds.height
            conversation.present(
                AgentUserInputRequest(questions: [
                    AgentUserQuestion(id: "answer", header: "Answer", prompt: "Continue?", kind: .text)
                ])
            )
            await settle(controller)
            let pendingList = try transcript(in: controller)
            #expect(ObjectIdentifier(pendingList) == ObjectIdentifier(list))
            checkScroll(pendingList, atBottom: false, originalOffset: originalOffset)
            if submit {
                conversation.setUserInputCustomAnswer("Continue", for: "answer")
                conversation.submitUserInput()
            } else {
                conversation.cancelUserInput()
            }
            await settle(controller)
            #expect(conversation.pendingUserInteraction == nil)
            let completedList = try transcript(in: controller)
            #expect(ObjectIdentifier(completedList) == ObjectIdentifier(list))
            #expect(abs(completedList.bounds.height - originalHeight) < 1)
            checkScroll(completedList, atBottom: false, originalOffset: originalOffset)
        }
    }

    private func makeConversation(in app: MobileAppModel) -> MobileAssistantSceneModel {
        let model = app.assistant.makeSceneModel()
        for index in 0..<30 {
            model.conversation.appendUserTurn("Message \(index): " + String(repeating: "History text. ", count: 10))
        }
        return model
    }

    private func transcript(in controller: UIViewController) throws -> ListScrollView {
        try #require(descendant(of: ListScrollView.self, in: controller.view))
    }

    private func checkScroll(_ list: ListScrollView, atBottom: Bool, originalOffset: CGFloat) {
        if atBottom {
            #expect(list.isScrolledToBottom(tolerance: 1))
        } else {
            #expect(abs(list.contentOffset.y - originalOffset) < 1)
        }
    }

    private func withConversation(
        app: MobileAppModel, model: MobileAssistantSceneModel,
        test: (UIViewController) async throws -> Void
    ) async throws {
        let controller = UIHostingController(rootView: ConversationHost(app: app, model: model))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        await settle(controller)
        try await test(controller)
    }

    private func settle(_ controller: UIViewController) async {
        for _ in 0..<20 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct ConversationHost: View {
        let app: MobileAppModel
        let model: MobileAssistantSceneModel
        @FocusState private var focused: Bool

        var body: some View {
            MobileAssistantConversation(
                app: app, model: model, conversation: model.conversation,
                composerFocus: $focused, composerFocusRequest: nil, composerFocusRequestHandled: { _ in }
            )
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.mobileReservedRegions, [])
        }
    }
}
