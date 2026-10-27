// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import ListViewKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileAssistantLayoutTests {
    @Test(.requiresKeyWindow)
    func composerKeepsNativeFocusAcrossDraftUpdates() async throws {
        let app = try MobileAppModel(inMemory: true)
        let model = app.assistant.makeSceneModel()
        let input = ComposerInputState()
        try await withConversation(app: app, model: model, input: input) { controller in
            let editor = try #require(descendant(of: MobileMessageTextView.self, in: controller.view))
            #expect(editor.bounds.height > 0)
            #expect(editor.isEditable)
            let window = try #require(editor.window)
            let point = editor.convert(CGPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: window)
            let hit = try #require(window.hitTest(point, with: nil))
            #expect(hit.isDescendant(of: editor))
            try #require(editor.becomeFirstResponder())
            await settle(controller)
            #expect(editor.isFirstResponder)
            #expect(input.focused)

            editor.insertText("Draft")
            await settle(controller)
            #expect(model.conversation.composer.draft == "Draft")
            #expect(editor.isFirstResponder)
            #expect(descendant(of: MobileMessageTextView.self, in: controller.view) === editor)
        }
    }

    @Test(.requiresKeyWindow)
    func composerCanDismissAndRestoreNativeFocus() async throws {
        let app = try MobileAppModel(inMemory: true)
        let model = app.assistant.makeSceneModel()
        let input = ComposerInputState()
        try await withConversation(app: app, model: model, input: input) { controller in
            let editor = try #require(descendant(of: MobileMessageTextView.self, in: controller.view))
            #expect(!editor.isFirstResponder)
            input.focused = true
            await settle(controller)
            #expect(editor.isFirstResponder)

            input.focused = false
            await settle(controller)
            #expect(!editor.isFirstResponder)

            input.request = 1
            await settle(controller)
            #expect(input.request == nil)
            #expect(input.focused)
            #expect(editor.isFirstResponder)

            editor.resignFirstResponder()
            await settle(controller)
            #expect(!input.focused)
            #expect(!editor.isFirstResponder)
        }
    }

    @Test(.requiresKeyWindow, arguments: [false, true], ["en", "zh-Hans", "zh-Hant"])
    func boundedApprovalKeepsDecisionButtonsVisibleInShortViewports(
        longContent: Bool, language: String
    ) async throws {
        let app = try MobileAppModel(inMemory: true)
        let model = makeConversation(in: app)
        let conversation = model.conversation
        let identity = Identity(name: "New Identity", username: "user")
        #expect(app.library.upsert(identity))
        let descriptor = AgentToolDescriptor(
            name: longContent ? "ssh_exec_run" : TermindToolName.deleteIdentity,
            summary: "", inputSchema: .object([:]), target: longContent ? .host : .local, approvalPolicy: .ask,
            presentation: longContent
                ? .init(
                    symbol: "terminal", activity: .semanticArgument(key: "command", fallback: .sshCommand),
                    presenterID: "builtin.ssh_exec_run", actionKind: .run)
                : .init(
                    symbol: "person.crop.circle", activity: .semanticLabel(.identities),
                    presenterID: "builtin.resource_management", actionKind: .delete))
        let request = AgentApprovalRequest(
            invocation: .init(
                runID: UUID(),
                call: .init(
                    id: "approval", name: descriptor.name,
                    arguments: .object(
                        longContent
                            ? ["command": .string(Array(repeating: "echo inspect", count: 80).joined(separator: "\n"))]
                            : ["identity_id": .string(identity.id.uuidString)]))),
            descriptor: descriptor, userIntent: "Review the operation")
        let answer = Task { await conversation.requestApproval(request) }
        defer { conversation.respondToApproval(request.id, allow: false) }
        for _ in 0..<100 where conversation.pendingApproval == nil { await Task.yield() }
        #expect(conversation.pendingApproval?.id == request.id)

        let locale = Locale(identifier: language)
        try await withConversation(app: app, model: model, language: language) { controller in
            for category in [UIContentSizeCategory.large, .accessibilityExtraLarge] {
                controller.traitOverrides.preferredContentSizeCategory = category
                for size in [
                    CGSize(width: 390, height: 640), CGSize(width: 844, height: 390),
                    CGSize(width: 1_024, height: 768),
                ] {
                    controller.view.window?.frame = CGRect(origin: .zero, size: size)
                    controller.view.frame = CGRect(origin: .zero, size: size)
                    await settle(controller)
                    if longContent {
                        let scroller = try #require(
                            scrollViews(in: controller.view).last {
                                !($0 is ListScrollView) && $0.isScrollEnabled
                                    && $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height + 1
                            })
                        scroller.setContentOffset(
                            CGPoint(x: 0, y: scroller.contentSize.height - scroller.bounds.height), animated: false)
                        await settle(controller)
                        #expect(scroller.contentOffset.y > 0)
                    }
                    let viewport = controller.view.convert(controller.view.bounds, to: nil)
                        .insetBy(dx: -1, dy: -1)
                    for title in [
                        AppLocalization.resolve(AppStrings.Common.deny, locale: locale),
                        AppLocalization.resolve(AppStrings.Assistant.allowOnce, locale: locale),
                    ] {
                        let button = try #require(accessibilityButton(in: controller.view, label: title))
                        #expect(button.accessibilityFrame.height > 0)
                        #expect(viewport.contains(button.accessibilityFrame))
                    }
                    if ProcessInfo.processInfo.environment["TERMIND_APPROVAL_SCREENSHOTS"] == "1" {
                        let data = UIGraphicsImageRenderer(bounds: controller.view.bounds).pngData { _ in
                            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                        }
                        Attachment.record(
                            data,
                            named:
                                "approval-ios-\(longContent ? "long" : "short")-\(language)-\(Int(size.width))-\(category.rawValue).png"
                        )
                    }
                }
            }
        }
        conversation.respondToApproval(request.id, allow: false)
        _ = await answer.value
    }

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
        language: String = "en",
        input: ComposerInputState = ComposerInputState(),
        test: (UIViewController) async throws -> Void
    ) async throws {
        let controller = UIHostingController(
            rootView: ConversationHost(app: app, model: model, input: input)
                .environment(\.locale, Locale(identifier: language)))
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

    private func accessibilityButton(in root: NSObject, label: String) -> NSObject? {
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: NSObject) -> NSObject? {
            guard seen.insert(ObjectIdentifier(element)).inserted else { return nil }
            if element.accessibilityTraits.contains(.button), element.accessibilityLabel == label {
                return element
            }
            var children: [NSObject] = (element as? UIView)?.subviews ?? []
            let count = element.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                children += (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject }
            }
            for child in children {
                if let button = visit(child) { return button }
            }
            return nil
        }
        return visit(root)
    }

    private func scrollViews(in root: UIView) -> [UIScrollView] {
        let current = (root as? UIScrollView).map { [$0] } ?? []
        return current + root.subviews.flatMap { scrollViews(in: $0) }
    }

    @Observable fileprivate final class ComposerInputState {
        var focused = false
        var request: Int?
    }

    private struct ConversationHost: View {
        let app: MobileAppModel
        let model: MobileAssistantSceneModel
        @Bindable var input: ComposerInputState

        var body: some View {
            MobileAssistantConversation(
                app: app, model: model, conversation: model.conversation,
                composerFocus: $input.focused, composerFocusRequest: input.request,
                composerFocusRequestHandled: { if input.request == $0 { input.request = nil } }
            )
            .environment(\.mobileReservedRegions, [])
        }
    }
}
