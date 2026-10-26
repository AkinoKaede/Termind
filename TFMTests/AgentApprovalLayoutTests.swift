// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind
@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct AgentApprovalLayoutTests {
    @Test(arguments: [true, false], ["en", "zh-Hans", "zh-Hant"])
    func singleIdentityApprovalDoesNotFillTheInteractionSurface(isCompact: Bool, language: String) async throws {
        let library = HostLibraryModel()
        let identity = Identity(name: "New Identity", username: "user")
        #expect(library.upsert(identity))
        let app = AppModel(hosts: library)
        defer { app.shutdownForTermination() }
        let tool = ResourceManagementTool(
            specification: .init(resource: .identity, action: .delete), manager: app.resourceManagement)
        let request = AgentApprovalRequest(
            invocation: .init(
                runID: UUID(),
                call: .init(
                    id: "delete", name: tool.descriptor.name,
                    arguments: .object(["identity_id": .string(identity.id.uuidString)]))),
            descriptor: tool.registeredDescriptor, userIntent: "Delete the identity")
        let conversation = ConversationModel()
        let answer = Task { await conversation.requestApproval(request) }
        defer { conversation.respondToApproval(request.id, allow: false) }
        for _ in 0..<100 where conversation.pendingApproval == nil { await Task.yield() }
        #expect(conversation.pendingApproval?.id == request.id)

        let host = NSHostingController(
            rootView: ConversationView(conversation: conversation, isCompact: isCompact, region: .interaction)
                .environment(app)
                .environment(WindowModel())
                .environment(\.locale, Locale(identifier: language))
                .environment(\.dynamicTypeSize, .large)
                .environment(\.colorScheme, .light)
                .background(Color.white))
        let width: CGFloat = isCompact ? 320 : 1_000
        let compact = host.sizeThatFits(in: CGSize(width: width, height: 220))
        let roomy = host.sizeThatFits(in: CGSize(width: width, height: 1_000))
        #expect(compact.height > 0)
        #expect(abs(compact.height - roomy.height) < 1)
        #expect(roomy.height < 220)
        #expect(roomy.width <= width)

        if ProcessInfo.processInfo.environment["TERMIND_APPROVAL_SCREENSHOTS"] == "1" {
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: CGRect(origin: .zero, size: roomy),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            defer { window.close() }
            window.setContentSize(CGSize(width: width, height: roomy.height))
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: roomy.height)
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            Attachment.record(data, named: "approval-macos-\(language)-\(isCompact ? "sidebar" : "main").png")
        }

        conversation.respondToApproval(request.id, allow: false)
        _ = await answer.value
    }
}
