// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import SwiftUI
import TermindApplication
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@Suite @MainActor
struct AssistantApprovalDetailsLayoutTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [CGFloat(280), 390, 700, 1_000])
    func singleIdentityUsesItsNaturalHeight(language: String, width: CGFloat) throws {
        let id = UUID().uuidString
        let descriptor = AgentToolDescriptor(
            name: TermindToolName.deleteIdentity, summary: "", inputSchema: .object([:]),
            target: .local, approvalPolicy: .ask,
            presentation: .init(
                symbol: "person.crop.circle", activity: .semanticLabel(.identities),
                presenterID: "builtin.resource_management", actionKind: .delete))
        let request = AgentApprovalRequest(
            invocation: .init(
                runID: UUID(),
                call: .init(id: "delete", name: descriptor.name, arguments: .object(["identity_id": .string(id)]))),
            descriptor: descriptor, userIntent: "Delete the identity")
        let locale = Locale(identifier: language)
        let presentation = TermindToolPresentationProfiles.renderer.approval(
            for: request, presenter: TermindAgentTools.presenter(for: descriptor),
            resourceNames: [id: .string("New Identity")], locale: locale)
        #expect(presentation.detail.layout.boundsApprovalHeight)
        #expect(presentation.detail.items.count == 1)

        for typeSize in [DynamicTypeSize.large, .accessibility3] {
            let details = AssistantApprovalDetails(
                detail: presentation.detail, reasons: [], showsSafetyDetails: .constant(false), resourceStyle: true
            )
            .environment(\.locale, locale)
            .environment(\.dynamicTypeSize, typeSize)
            let natural = measure(
                AssistantToolDetails(items: presentation.detail.items, resourceStyle: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.locale, locale)
                    .environment(\.dynamicTypeSize, typeSize),
                width: width, height: 1_000)
            for height: CGFloat in [320, 1_000] {
                let size = measure(details, width: width, height: height)
                #expect(size.height > 0)
                #expect(abs(size.height - natural.height) < 1)
                #expect(size.width <= width + 1)
            }
        }
    }

    @Test(arguments: [CGFloat(280), 700], [false, true])
    func longDetailsRespectBothTheToolCapAndAvailableHeight(width: CGFloat, textBlock: Bool) {
        let items: [AgentToolDetail.Item] =
            textBlock
            ? [
                .text(
                    .init(
                        text: Array(repeating: "Review this command", count: 80).joined(separator: "\n"),
                        style: .monospaced))
            ]
            : (0..<40).map { .field(.init(label: "Argument \($0)", value: "Review this value")) }
        let details = AssistantApprovalDetails(
            detail: .init(items: items, layout: .init(boundsApprovalHeight: true)),
            reasons: [], showsSafetyDetails: .constant(false), resourceStyle: !textBlock
        )
        .environment(\.dynamicTypeSize, .large)
        for height: CGFloat in [80, 200, 640] {
            let size = measure(details, width: width, height: height)
            #expect(abs(size.height - min(height, 240)) < 1)
            #expect(size.width <= width + 1)
        }
    }

    @Test func unboundedToolsStillUseTheAvailableHeight() {
        let details = AssistantApprovalDetails(
            detail: .init(
                items: (0..<80).map { .field(.init(label: "Argument \($0)", value: "Review this value")) }),
            reasons: [], showsSafetyDetails: .constant(false))
        for height: CGFloat in [80, 320, 640] {
            #expect(abs(measure(details, width: 390, height: height).height - height) < 1)
        }
    }

    @Test func safetyDisclosureGrowsOnlyAsNeededAndCollapsesBack() async throws {
        let detail = AgentToolDetail(
            items: [.field(.init(label: "Identity", value: "New Identity"))],
            layout: .init(boundsApprovalHeight: true))
        let reasons = (0..<30).map { "Reason \($0): verify this operation before allowing it." }
        func content(expanded: Bool) -> some View {
            AssistantApprovalDetails(
                detail: detail, reasons: reasons, showsSafetyDetails: .constant(expanded), resourceStyle: true
            )
            .environment(\.dynamicTypeSize, .large)
            .transaction { $0.disablesAnimations = true }
        }
        #if os(macOS)
            let host = NSHostingController(rootView: content(expanded: false))
        #else
            let host = UIHostingController(rootView: content(expanded: false))
        #endif
        let proposal = CGSize(width: 320, height: 640)
        host.view.frame = CGRect(origin: .zero, size: proposal)
        func layout() {
            #if os(macOS)
                host.view.needsLayout = true
                host.view.layoutSubtreeIfNeeded()
            #else
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
            #endif
        }
        layout()
        let collapsed = host.sizeThatFits(in: proposal).height
        host.rootView = content(expanded: true)
        try await Task.sleep(for: .milliseconds(50))
        layout()
        let expanded = host.sizeThatFits(in: proposal).height
        #expect(expanded > collapsed)
        #expect(abs(expanded - 240) < 1)
        #expect(abs(host.sizeThatFits(in: CGSize(width: 320, height: 100)).height - 100) < 1)
        host.rootView = content(expanded: false)
        try await Task.sleep(for: .milliseconds(50))
        layout()
        #expect(abs(host.sizeThatFits(in: proposal).height - collapsed) < 1)
    }

    #if os(iOS)
        @Test func approvalCapScalesWithAccessibilityType() {
            let details = AssistantApprovalDetails(
                detail: .init(
                    items: (0..<80).map { .field(.init(label: "Argument \($0)", value: "Review this value")) },
                    layout: .init(boundsApprovalHeight: true)),
                reasons: [], showsSafetyDetails: .constant(false))
            let standard = measure(
                details.environment(\.dynamicTypeSize, .large), width: 390, height: 2_000)
            let accessible = measure(
                details.environment(\.dynamicTypeSize, .accessibility3), width: 390, height: 2_000)
            #expect(accessible.height > standard.height)
            #expect(
                abs(
                    measure(details.environment(\.dynamicTypeSize, .accessibility3), width: 390, height: 100).height
                        - 100) < 1)
        }
    #endif

    private func measure(_ content: some View, width: CGFloat, height: CGFloat) -> CGSize {
        #if os(macOS)
            let host = NSHostingController(rootView: content)
        #else
            let host = UIHostingController(rootView: content)
        #endif
        return host.sizeThatFits(in: CGSize(width: width, height: height))
    }
}
