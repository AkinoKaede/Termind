import AgentKit
import ListViewKit
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileAssistantTranscriptTests {
    @Test func userBubbleShrinksForShortTextAndWrapsAtTheAvailableWidth() {
        func measuredWidth(_ text: String) -> CGFloat {
            let controller = UIHostingController(rootView: MobileAssistantUserBubble(text: text))
            return controller.sizeThatFits(in: CGSize(width: 320, height: 1_000)).width
        }

        let short = measuredWidth("Hi")
        let long = measuredWidth(String(repeating: "A long message that should wrap. ", count: 20))
        #expect(short < 160)
        #expect(long > short)
        #expect(long <= 320)
    }

    @Test func activityUsesTheAvailableWidthToKeepItsTitleLeading() {
        let controller = UIHostingController(rootView: MobileAssistantActivity())
        let size = controller.sizeThatFits(in: CGSize(width: 320, height: 1_000))

        #expect(size.width == 320)
    }

    @Test func imageFlowKeepsEveryUserRowTrailingAndAssistantRowsLeading() {
        let tile = CGSize(width: 104, height: 104)
        let sizes = Array(repeating: tile, count: 5)

        let user = MobileAssistantImageFlowLayout.placements(
            for: sizes,
            in: 320,
            spacing: 8,
            alignment: .trailing
        )
        #expect(user.map(\.index) == [0, 1, 2, 3, 4])
        #expect(user.map(\.size) == sizes)
        #expect(user[0].origin == CGPoint(x: 104, y: 0))
        #expect(user[1].origin == CGPoint(x: 216, y: 0))
        #expect(user[2].origin == CGPoint(x: 104, y: 112))
        #expect(user[3].origin == CGPoint(x: 216, y: 112))
        #expect(user[4].origin == CGPoint(x: 216, y: 224))
        #expect(user[1].origin.x + user[1].size.width == 320)
        #expect(user[3].origin.x + user[3].size.width == 320)
        #expect(user[4].origin.x + user[4].size.width == 320)

        let assistant = MobileAssistantImageFlowLayout.placements(
            for: sizes,
            in: 320,
            spacing: 8,
            alignment: .leading
        )
        #expect(assistant[0].origin.x == 0)
        #expect(assistant[2].origin.x == 0)
        #expect(assistant[4].origin.x == 0)
    }

    @Test func scanningStopsForReducedMotionMeasurementAndInactiveScenes() async throws {
        // This owns a foreground window, so run it with the opt-in visual checks
        // rather than competing with unrelated native toolbar tests.
        guard ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1" else { return }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for (displayed, reduced, active) in [
            (true, false, true), (true, true, true), (false, false, true), (true, false, false),
        ] {
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(
                rootView:
                    Text("Working…").font(.title).foregroundStyle(.black)
                    .modifier(MobileAssistantScanning(active: true))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(.white)
                    .environment(\.mobileListRowIsDisplayed, displayed)
                    .environment(\.mobileListReduceMotion, reduced)
                    .environment(\.mobileListSceneIsActive, active)
            )
            window.rootViewController = controller
            window.windowLevel = .alert + 3
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            func snapshot() throws -> Data {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                return try #require(image.pngData())
            }
            let first = try snapshot()
            try await Task.sleep(for: .milliseconds(250))
            let second = try snapshot()
            let directory = FileManager.default.temporaryDirectory.appending(path: "assistant-screenshots")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try first.write(to: directory.appending(path: "motion-\(displayed)-\(reduced)-\(active)-first.png"))
            try second.write(to: directory.appending(path: "motion-\(displayed)-\(reduced)-\(active)-second.png"))
            if displayed && !reduced && active {
                #expect(first != second, "The live title should scan.")
            } else {
                #expect(first == second, "A static title must not animate.")
            }
        }
    }

    @Test func streamedUpdatesAndDisclosureRevisionsKeepTheHostedView() throws {
        let harness = Harness()
        let first = message("First")
        let second = message("Second")
        harness.update([first, second])
        let row = try #require(harness.list.rowView(for: first.id))
        let hosted = try #require(row.subviews.first?.subviews.first)
        harness.renderedIDs.removeAll()
        var streaming = first
        streaming.text += " delta"
        harness.update([streaming, second])
        #expect(harness.list.rowView(for: first.id) === row)
        #expect(row.subviews.first?.subviews.first === hosted)
        #expect(!harness.renderedIDs.contains(second.id))
        harness.renderedIDs.removeAll()
        harness.revisions[first.id] = 1
        harness.update([streaming, second])
        #expect(harness.renderedIDs.contains(first.id))
        #expect(!harness.renderedIDs.contains(second.id))
        #expect(row.subviews.first?.subviews.first === hosted)
    }

    @Test func appendingDoesNotReplaceExistingRowsOrFollowWhileReadingHistory() async throws {
        let harness = Harness()
        let items = (0..<30).map { message("Message \($0)") }
        harness.update(items)
        harness.list.setContentOffset(CGPoint(x: 0, y: 120), animated: false)
        harness.list.layoutIfNeeded()
        let offset = harness.list.contentOffset.y
        let visible = try #require(harness.list.indicesForVisibleRows.first)
        let row = try #require(harness.list.rowView(for: items[visible].id))
        harness.update(items + [message("New tail")], followsBottom: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(harness.list.rowView(for: items[visible].id) === row)
        #expect(abs(harness.list.contentOffset.y - offset) < 1)
    }

    @Test func visibleWorkCollapsesOnlyAfterItFullyLeavesTheMobileViewport() async throws {
        typealias Adapter = MobileNativeList<AssistantTranscriptEntry, Text>
        let presentation = AssistantTranscriptPresentationState()
        let coordinator = Adapter.Coordinator()
        let list = ListView<AssistantTranscriptEntry>()
        list.frame = CGRect(x: 0, y: 0, width: 390, height: 180)
        list.rows {
            ListRow(MobileHostingListRow.self).height { _, _ in 100 }.configure { row, item, _ in
                coordinator.configure(row, item: item, surface: .plain)
            }
        }
        coordinator.observeViewport(of: list)
        defer { coordinator.stopObservingViewport() }
        let id = UUID()
        let tail = (0..<12).map { _ in AssistantTranscriptEntry(id: UUID(), content: .empty) }
        func update(_ state: AgentRunState) {
            let run = AgentRunSummary(id: id, state: state, startedAt: .now)
            let entry = AssistantTranscriptEntry(
                id: id,
                content: .work(
                    .init(
                        run: run, items: [], orderedAt: .now, appearsAfterAnswer: false
                    )))
            coordinator.update(
                listView: list, items: [entry] + tail, renderer: { _ in AnyView(Text("Work")) },
                onSelect: nil, onRefresh: nil, followsBottom: false, surface: .plain,
                refreshID: 0, locale: Locale(identifier: "en"), colorScheme: .light, dynamicTypeSize: .large,
                prepareUpdate: { presentation.prepareWorkCompletionTransitions(from: $0, to: $1, visibleIDs: $2) },
                onViewportChange: { presentation.collapseWorkOutsideViewport(visibleIDs: $0) }
            )
            list.layoutIfNeeded()
        }
        update(.running)
        update(.completed)
        #expect(presentation.hasPendingAutoCollapse(id))
        let frame = list.rectForRow(with: id)
        list.setContentOffset(CGPoint(x: 0, y: frame.maxY - 1), animated: false)
        list.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(presentation.isExpanded(.work(id)))
        list.setContentOffset(CGPoint(x: 0, y: frame.maxY + 1), animated: false)
        list.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!presentation.isExpanded(.work(id)))
        #expect(!presentation.hasPendingAutoCollapse(id))
    }

    @Test func nativeListTapCallbackRecognizesAlongsideHostedRowControls() throws {
        typealias Adapter = MobileNativeList<ChatMessage, Text>
        let coordinator = Adapter.Coordinator()
        let list = ListView<ChatMessage>()
        var tapCount = 0
        coordinator.installTapRecognizer(on: list)
        coordinator.update(
            listView: list,
            items: [],
            renderer: { _ in AnyView(Text("Message")) },
            onSelect: nil,
            onRefresh: nil,
            followsBottom: false,
            surface: .plain,
            refreshID: 0,
            locale: Locale(identifier: "en"),
            colorScheme: .light,
            dynamicTypeSize: .large,
            onTap: { tapCount += 1 }
        )

        let tap = try #require(list.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }.first)
        #expect(tap.cancelsTouchesInView == false)
        #expect(tap.delegate === coordinator)
        #expect(
            coordinator.gestureRecognizer(
                tap,
                shouldRecognizeSimultaneouslyWith: UITapGestureRecognizer()
            ))
        coordinator.listTapped()
        #expect(tapCount == 1)
    }

    private func message(_ text: String) -> ChatMessage { .init(role: .assistant, text: text, isStreaming: true) }

    private final class Harness {
        let coordinator = MobileNativeList<ChatMessage, Text>.Coordinator()
        let list = ListView<ChatMessage>()
        var revisions: [UUID: UInt64] = [:]
        var renderedIDs: [UUID] = []

        init() {
            list.frame = CGRect(x: 0, y: 0, width: 390, height: 280)
            list.rows {
                ListRow(MobileHostingListRow.self).height { _, _ in 80 }.configure { [weak self] row, item, _ in
                    self?.coordinator.configure(row, item: item, surface: .plain)
                }
            }
        }

        func update(_ items: [ChatMessage], followsBottom: Bool = false) {
            coordinator.update(
                listView: list, items: items,
                renderer: { [weak self] item in
                    self?.renderedIDs.append(item.id)
                    return AnyView(Text(item.text))
                }, onSelect: nil, onRefresh: nil, followsBottom: followsBottom, surface: .plain,
                refreshID: 0, locale: Locale(identifier: "en"), colorScheme: .light, dynamicTypeSize: .large,
                rowRevision: { [weak self] in self?.revisions[$0.id] ?? 0 }
            )
            list.layoutIfNeeded()
        }
    }
}
