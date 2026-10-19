import AgentKit
import AppKit
import Foundation
import ListViewKit
import MarkdownView
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
struct TranscriptListUpdatePlanTests {
    @Test
    func firstSnapshotUsesApply() {
        let plan = TranscriptListUpdatePlan.make(old: [], new: [item(1)])

        #expect(plan.replacesAll)
        #expect(plan.updates.isEmpty)
        #expect(plan.appends.isEmpty)
    }

    @Test
    func pureTailGrowthUsesAppendWithoutRevisitingExistingRows() {
        let first = item(1)
        let second = item(2)
        let plan = TranscriptListUpdatePlan.make(old: [first], new: [first, second])

        #expect(!plan.replacesAll)
        #expect(plan.updates.isEmpty)
        #expect(plan.appends == [second])
    }

    @Test
    func aStreamingRevisionUpdatesOnlyItsStableRow() {
        let id = uuid(1)
        let old = TranscriptEntry(id: id, content: .empty)
        let new = TranscriptEntry(id: id, content: .interrupted)
        let untouched = item(2)
        let plan = TranscriptListUpdatePlan.make(
            old: [old, untouched], new: [new, untouched]
        )

        #expect(!plan.replacesAll)
        #expect(plan.updates == [new])
        #expect(plan.appends.isEmpty)
    }

    @Test
    func removalOrReorderingFallsBackToDiffedApply() {
        let first = item(1)
        let second = item(2)

        #expect(
            TranscriptListUpdatePlan.make(
                old: [first, second], new: [second, first]
            ).replacesAll)
        #expect(
            TranscriptListUpdatePlan.make(
                old: [first, second], new: [first]
            ).replacesAll)
    }

    @Test
    func appendingMarksOnlyTheNewRowForLeadingSpacing() {
        let firstTimeline = TimelineItem.message(
            ChatMessage(
                id: uuid(1), role: .assistant, text: "first"
            ))
        let secondTimeline = TimelineItem.message(
            ChatMessage(
                id: uuid(2), role: .assistant, text: "second"
            ))

        let old = TranscriptEntry.items(
            timeline: [firstTimeline], isInterrupted: false,
            canEdit: { _ in false }, canFork: { _ in false }
        )
        let new = TranscriptEntry.items(
            timeline: [firstTimeline, secondTimeline], isInterrupted: false,
            canEdit: { _ in false }, canFork: { _ in false }
        )
        let plan = TranscriptListUpdatePlan.make(old: old, new: new)

        #expect(!old[0].hasLeadingSpacing)
        #expect(!new[0].hasLeadingSpacing)
        #expect(new[1].hasLeadingSpacing)
        #expect(plan.updates.isEmpty)
        #expect(plan.appends == [new[1]])
    }

    private func item(_ value: UInt8) -> TranscriptEntry {
        TranscriptEntry(id: uuid(value), content: .empty)
    }

    private func uuid(_ value: UInt8) -> UUID {
        let bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value)
        return UUID(uuid: bytes)
    }
}

@MainActor
@Suite
struct TranscriptPresentationStateTests {
    @Test
    func messageDraftSurvivesRowRecyclingAndCanBePruned() {
        let id = UUID()
        let state = TranscriptPresentationState()

        state.beginEditingMessage(id, text: "draft")
        state.setMessageEditText("updated", for: id)
        state.setMessageBubbleWidth(240, for: id)

        #expect(state.isEditingMessage(id))
        #expect(state.messageEditText(id) == "updated")
        #expect(state.messageBubbleWidth(id) == 240)

        state.prune(validTimelineIDs: [])
        #expect(!state.isEditingMessage(id))
        #expect(state.messageEditText(id).isEmpty)
    }
}

@MainActor
@Suite
struct TranscriptListCacheTests {
    @Test
    func fullScreenAndSidebarUseIndependentNativeLists() {
        let cache = TranscriptListCache()
        let conversationID = UUID()
        let fullScreen = cache.owner(
            for: .init(
                conversationID: conversationID, surface: .fullScreen
            )
        )
        let sidebar = cache.owner(
            for: .init(
                conversationID: conversationID, surface: .sidebar
            )
        )

        #expect(fullScreen !== sidebar)
        #expect(fullScreen.listView !== sidebar.listView)
        #expect(cache.count == 2)
    }

    @Test
    func leastRecentlyUsedUnmountedListIsEvictedAtTheLimit() {
        let cache = TranscriptListCache(limit: 8)
        let keys = (0..<9).map { index in
            TranscriptCacheKey(
                conversationID: UUID(),
                surface: index.isMultiple(of: 2) ? .fullScreen : .sidebar
            )
        }
        for key in keys.prefix(8) { _ = cache.owner(for: key) }

        _ = cache.owner(for: keys[0])
        _ = cache.owner(for: keys[8])

        #expect(cache.count == 8)
        #expect(cache.cachedOwner(for: keys[0]) != nil)
        #expect(cache.cachedOwner(for: keys[1]) == nil)
        #expect(cache.cachedOwner(for: keys[8]) != nil)
    }

    @Test
    func mountedListDefersEvictionUntilItUnmounts() {
        let cache = TranscriptListCache(limit: 1)
        let firstKey = TranscriptCacheKey(
            conversationID: UUID(), surface: .fullScreen
        )
        let secondKey = TranscriptCacheKey(
            conversationID: UUID(), surface: .fullScreen
        )
        let first = cache.owner(for: firstKey)
        let container = TranscriptMountView()
        first.mount(in: container)

        _ = cache.owner(for: secondKey)
        #expect(cache.count == 2)
        #expect(cache.cachedOwner(for: firstKey) === first)

        first.unmount(from: container)
        #expect(cache.count == 1)
        #expect(cache.cachedOwner(for: firstKey) == nil)
        #expect(cache.cachedOwner(for: secondKey) != nil)
    }

    @Test
    func remountKeepsNativeIdentityAndReaderOffset() {
        let owner = PersistentTranscriptListOwner(
            key: .init(
                conversationID: UUID(), surface: .fullScreen
            )
        )
        let firstContainer = TranscriptMountView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        owner.mount(in: firstContainer)
        firstContainer.layoutSubtreeIfNeeded()
        let entries = (0..<12).map { _ in TranscriptEntry(id: UUID(), content: .empty) }
        update(owner, entries: entries)
        owner.listView.setContentOffset(CGPoint(x: 0, y: 72), animated: false)
        let offset = owner.listView.contentOffset
        let nativeList = owner.listView

        owner.unmount(from: firstContainer)
        let secondContainer = TranscriptMountView(frame: firstContainer.frame)
        owner.mount(in: secondContainer)
        secondContainer.layoutSubtreeIfNeeded()

        #expect(owner.listView === nativeList)
        #expect(owner.listView.superview === secondContainer)
        #expect(owner.listView.contentOffset == offset)
    }

    @Test
    func detachedBottomFollowerCatchesUpButHistoryReaderStaysPut() {
        let owner = PersistentTranscriptListOwner(
            key: .init(
                conversationID: UUID(), surface: .fullScreen
            )
        )
        let firstContainer = TranscriptMountView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 180)
        )
        owner.mount(in: firstContainer)
        firstContainer.layoutSubtreeIfNeeded()
        var entries = (0..<12).map { _ in TranscriptEntry(id: UUID(), content: .empty) }
        update(owner, entries: entries)
        owner.listView.scrollToBottom(animated: false)
        owner.unmount(from: firstContainer)

        entries.append(TranscriptEntry(id: UUID(), content: .empty))
        let secondContainer = TranscriptMountView(frame: firstContainer.frame)
        owner.mount(in: secondContainer)
        secondContainer.layoutSubtreeIfNeeded()
        update(owner, entries: entries)
        #expect(owner.listView.contentOffset.y == owner.listView.maximumContentOffset.y)

        owner.listView.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
        let readerOffset = owner.listView.contentOffset
        owner.unmount(from: secondContainer)
        entries.append(TranscriptEntry(id: UUID(), content: .empty))
        let thirdContainer = TranscriptMountView(frame: firstContainer.frame)
        owner.mount(in: thirdContainer)
        thirdContainer.layoutSubtreeIfNeeded()
        update(owner, entries: entries)

        #expect(owner.listView.contentOffset == readerOffset)
        #expect(!owner.listView.isScrolledToBottom(tolerance: Metrics.Space.l))
    }

    @Test
    func deletingClearsBothSurfacesWhileArchivingKeepsThem() {
        let window = WindowModel()
        let conversation = window.assistantLibrary.createConversation()
        let fullKey = TranscriptCacheKey(
            conversationID: conversation.id, surface: .fullScreen
        )
        let sidebarKey = TranscriptCacheKey(
            conversationID: conversation.id, surface: .sidebar
        )
        _ = window.transcriptCache.owner(for: fullKey)
        _ = window.transcriptCache.owner(for: sidebarKey)

        window.setAssistantArchived(conversation.id, archived: true)
        #expect(window.transcriptCache.count == 2)

        window.deleteAssistantConversation(conversation.id)
        #expect(window.transcriptCache.count == 0)
    }

    @Test
    func remountAtANewWidthReflowsWithoutReplacingTheListOrLeavingHistory() async throws {
        let owner = PersistentTranscriptListOwner(key: .init(conversationID: UUID(), surface: .fullScreen))
        let first = TranscriptMountView(frame: CGRect(x: 0, y: 0, width: 900, height: 220))
        owner.mount(in: first)
        first.layoutSubtreeIfNeeded()
        let entries = (0..<8).map { _ in
            let message = ChatMessage(
                id: UUID(), role: .assistant,
                text: String(repeating: "Keep the reader on this conversation while its width changes. ", count: 12)
            )
            return TranscriptEntry(id: message.id, content: .assistant(message, canFork: false))
        }
        update(owner, entries: entries)
        owner.listView.setContentOffset(CGPoint(x: 0, y: 60), animated: false)
        owner.listView.layoutSubtreeIfNeeded()
        let nativeList = owner.listView
        owner.unmount(from: first)

        let second = TranscriptMountView(frame: CGRect(x: 0, y: 0, width: 360, height: 220))
        owner.mount(in: second)
        second.layoutSubtreeIfNeeded()
        update(owner, entries: entries)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        second.layoutSubtreeIfNeeded()

        #expect(owner.listView === nativeList)
        #expect(!nativeList.isScrolledToBottom(tolerance: Metrics.Space.l))
        #expect(nativeList.contentOffset.y > 0)
        let row = try #require(nativeList.rowView(for: entries[0].id))
        #expect(abs(row.bounds.width - 360) <= 1)
        #expect(nativeList.rectForRow(with: entries[0].id).height > 200)
    }

    private func update(
        _ owner: PersistentTranscriptListOwner,
        entries: [TranscriptEntry]
    ) {
        owner.update(
            entries: entries,
            latestUserMessageID: nil,
            configuration: .init(
                isCompact: false,
                showsTerminalActions: false,
                isConversationStreaming: false,
                locale: Locale(identifier: "en"),
                reduceMotion: true,
                colorScheme: .light
            ),
            actions: .init()
        )
        owner.listView.layoutSubtreeIfNeeded()
    }
}

@MainActor
@Suite
struct TranscriptListViewBridgeTests {
    @Test
    func interactionMetadataPreservesEditorMarkdownMeasurementsAndHistoryAnchor() async throws {
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        list.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let presentation = TranscriptPresentationState()
        let userID = UUID()
        let answerID = UUID()
        let destinationID = UUID()
        let entries =
            [
                user(id: userID, text: "Original"),
                assistant(id: answerID, text: "**Retain this Markdown**"),
            ] + (0..<15).map { _ in TranscriptEntry(id: UUID(), content: .empty) }
        presentation.beginEditingMessage(userID, text: "Draft text")
        update(coordinator, list, entries: entries, presentation: presentation)
        list.setContentOffset(.zero, animated: false)
        await settleResize(list)
        let row = try #require(list.rowView(for: userID))
        let answer = try #require(list.rowView(for: answerID))
        let editor = try #require(descendant(in: row, identifier: "Transcript.UserEditorText") as? NSTextView)
        let markdown = try #require(descendant(in: answer, ofType: MarkdownTextView.self))
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        editor.setMarkedText(
            "中文", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let selection = editor.selectedRange()
        let marked = editor.markedRange()
        await settleResize(list)
        let anchorOffset = list.rectForRow(with: userID).minY - list.contentOffset.y
        var measurements = 0
        let measurementConfiguration = TranscriptListConfiguration(
            isCompact: true, showsTerminalActions: false, isConversationStreaming: false,
            locale: Locale(identifier: "en"), reduceMotion: true, colorScheme: .light)
        func probeMeasurement() {
            _ = coordinator.sizingPool.height(
                for: entries[0], width: 601, configuration: measurementConfiguration, presentation: presentation
            ) { _ in measurements += 1 }
        }
        probeMeasurement()
        for (streaming, title) in [(true, "First title"), (true, "Renamed"), (false, "Renamed")] {
            update(
                coordinator, list, entries: entries, presentation: presentation,
                isConversationStreaming: streaming, chatDestinations: [destinationID: title])
            list.layoutSubtreeIfNeeded()
            #expect(list.rowView(for: userID) === row)
            #expect(list.rowView(for: answerID) === answer)
            #expect(descendant(in: row, identifier: "Transcript.UserEditorText") === editor)
            #expect(descendant(in: answer, ofType: MarkdownTextView.self) === markdown)
            #expect(editor.selectedRange() == selection)
            #expect(editor.markedRange() == marked)
            #expect(editor.hasMarkedText())
            #expect(abs(list.rectForRow(with: userID).minY - list.contentOffset.y - anchorOffset) <= 1)
            probeMeasurement()
            #expect(measurements == 1)
        }
        coordinator.refreshDisplayedRow(userID, in: list)
        #expect(descendant(in: row, identifier: "Transcript.UserEditorText") === editor)
    }

    @Test
    func modelRunBoundariesPreserveAnActiveMessageEditorWhenEditEligibilityChanges() async throws {
        let conversation = ConversationModel()
        let messageID = conversation.appendUserTurnContent("Original message").id
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        list.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        let presentation = TranscriptPresentationState()
        presentation.beginEditingMessage(messageID, text: "Draft text")
        func applyConversation() {
            let availability = conversation.messageActionAvailability
            let entries = TranscriptEntry.items(
                timeline: conversation.timeline,
                isInterrupted: conversation.runState == .interrupted,
                canEdit: availability.editable.contains,
                canFork: availability.forkable.contains
            )
            update(
                coordinator, list, entries: entries, presentation: presentation,
                isConversationStreaming: conversation.isStreaming)
        }
        #expect(conversation.messageActionAvailability.editable.contains(messageID))
        applyConversation()
        await settleResize(list)
        let row = try #require(list.rowView(for: messageID))
        let editor = try #require(descendant(in: row, identifier: "Transcript.UserEditorText") as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        editor.setMarkedText(
            "中文", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        let selection = editor.selectedRange()
        let marked = editor.markedRange()
        for state: AgentRunState in [.running, .completed] {
            conversation.handle(.runState(state))
            #expect(conversation.messageActionAvailability.editable.contains(messageID) == !conversation.isStreaming)
            applyConversation()
            #expect(presentation.isEditingMessage(messageID))
            #expect(list.rowView(for: messageID) === row)
            #expect(descendant(in: row, identifier: "Transcript.UserEditorText") === editor)
            #expect(editor.selectedRange() == selection)
            #expect(editor.markedRange() == marked)
            #expect(editor.hasMarkedText())
        }
    }

    @Test
    func interactionMetadataDoesNotSnapANearBottomReaderToBottom() async {
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        let presentation = TranscriptPresentationState()
        list.frame = CGRect(x: 0, y: 0, width: 420, height: 220)
        let entries = (0..<15).map { _ in TranscriptEntry(id: UUID(), content: .empty) }
        update(coordinator, list, entries: entries, presentation: presentation)
        await settleResize(list)
        list.setContentOffset(CGPoint(x: 0, y: list.maximumContentOffset.y - 8), animated: false)
        let offset = list.contentOffset
        #expect(list.isScrolledToBottom(tolerance: Metrics.Space.l))
        update(coordinator, list, entries: entries, presentation: presentation, isConversationStreaming: true)
        #expect(list.contentOffset == offset)
    }

    @Test
    func interactionMetadataUpdatesRetainedPlanAndOriginControlsInBothDirections() async throws {
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        list.frame = CGRect(x: 0, y: 0, width: 600, height: 1200)
        let presentation = TranscriptPresentationState()
        let sourceID = UUID()
        let message = ChatMessage(
            role: .user, text: "Delegated request",
            origin: AgentMessageOrigin(
                sourceConversationID: sourceID, sourceRunID: UUID(), sourceToolCallID: "send",
                sourceTitle: "Snapshot title"))
        let plan = AgentPlan(title: "Plan", body: "Implement this", scratchPath: "/tmp/plan.md")
        let entries = [
            TranscriptEntry(id: message.id, content: .user(message, canEdit: false)),
            TranscriptEntry(id: plan.id, content: .plan(AgentPlanCard(plan: plan))),
        ]
        var navigations: [UUID] = []
        var implementations: [UUID] = []
        let actions = TranscriptListActions(
            navigateChat: { navigations.append($0) }, implementPlan: { implementations.append($0.id) })
        update(
            coordinator, list, entries: entries, presentation: presentation, actions: actions,
            chatDestinations: [sourceID: "Live title"])
        await settleResize(list)
        let originRow = try #require(list.rowView(for: message.id))
        let planRow = try #require(list.rowView(for: plan.id))
        let origin = try #require(descendant(in: originRow, identifier: "Transcript.AgentOrigin") as? NSButton)
        let implement = try #require(descendant(in: planRow, identifier: "Transcript.PlanImplement") as? NSButton)
        for (streaming, destinations, expectedTitle) in [
            (true, [sourceID: "Renamed"], "Renamed"),
            (false, [:], "Snapshot title"),
            (false, [sourceID: "Restored"], "Restored"),
        ] {
            update(
                coordinator, list, entries: entries, presentation: presentation, actions: actions,
                isConversationStreaming: streaming, chatDestinations: destinations)
            #expect(list.rowView(for: message.id) === originRow)
            #expect(list.rowView(for: plan.id) === planRow)
            #expect(descendant(in: originRow, identifier: "Transcript.AgentOrigin") === origin)
            #expect(descendant(in: planRow, identifier: "Transcript.PlanImplement") === implement)
            #expect(implement.isEnabled == !streaming)
            #expect(origin.isEnabled == (destinations[sourceID] != nil))
            let help = AppLocalization.resolve(
                AppStrings.Assistant.agentFrom(expectedTitle), locale: Locale(identifier: "en"))
            #expect(origin.toolTip == help)
            #expect(origin.accessibilityLabel() == help)
        }
        origin.performClick(nil)
        implement.performClick(nil)
        #expect(navigations == [sourceID])
        #expect(implementations == [plan.id])
    }

    @Test
    func offscreenPlanUsesLatestInteractionMetadataWhenMountedAgain() async throws {
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        list.frame = CGRect(x: 0, y: 0, width: 420, height: 220)
        let presentation = TranscriptPresentationState()
        let plan = AgentPlan(title: "Plan", body: "Implement this", scratchPath: "/tmp/plan.md")
        let entries =
            [TranscriptEntry(id: plan.id, content: .plan(AgentPlanCard(plan: plan)))]
            + (0..<40).map { _ in TranscriptEntry(id: UUID(), content: .empty) }
        update(coordinator, list, entries: entries, presentation: presentation)
        await settleResize(list)
        #expect(list.rowView(for: plan.id) == nil)
        update(coordinator, list, entries: entries, presentation: presentation, isConversationStreaming: true)
        list.setContentOffset(.zero, animated: false)
        list.layoutSubtreeIfNeeded()
        let row = try #require(list.rowView(for: plan.id))
        let implement = try #require(descendant(in: row, identifier: "Transcript.PlanImplement") as? NSButton)
        #expect(!implement.isEnabled)
        update(coordinator, list, entries: entries, presentation: presentation)
        #expect(descendant(in: row, identifier: "Transcript.PlanImplement") === implement)
        #expect(implement.isEnabled)
    }

    @Test
    func simultaneousContentAndInteractionChangesApplyImmediatelyWithoutReplacingUnchangedRows() async throws {
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        list.frame = CGRect(x: 0, y: 0, width: 600, height: 1200)
        let presentation = TranscriptPresentationState()
        let stable = assistant(id: UUID(), text: "Stable **Markdown**")
        let streamingID = UUID()
        let plan = AgentPlan(title: "Plan", body: "Implement this", scratchPath: "/tmp/plan.md")
        let planEntry = TranscriptEntry(id: plan.id, content: .plan(AgentPlanCard(plan: plan)))
        update(
            coordinator, list, entries: [stable, streamingAssistant(id: streamingID, text: "First"), planEntry],
            presentation: presentation)
        await settleResize(list)
        let row = try #require(list.rowView(for: stable.id))
        let markdown = try #require(descendant(in: row, ofType: MarkdownTextView.self))
        let planRow = try #require(list.rowView(for: plan.id))
        let implement = try #require(descendant(in: planRow, identifier: "Transcript.PlanImplement") as? NSButton)
        let revised = streamingAssistant(id: streamingID, text: "First delta")
        update(
            coordinator, list, entries: [stable, revised, planEntry], presentation: presentation,
            isConversationStreaming: true)
        #expect(list.content[1] == revised)
        #expect(list.rowView(for: stable.id) === row)
        #expect(descendant(in: row, ofType: MarkdownTextView.self) === markdown)
        #expect(descendant(in: planRow, identifier: "Transcript.PlanImplement") === implement)
        #expect(!implement.isEnabled)
    }

    @Test
    func interactionMetadataRefreshesNestedToolNavigationWithoutRebuildingWork() async throws {
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        list.frame = CGRect(x: 0, y: 0, width: 600, height: 1200)
        let presentation = TranscriptPresentationState()
        let runID = UUID()
        let destinationID = UUID()
        var card = AgentToolCard(
            invocation: AgentToolInvocation(
                runID: runID, call: AgentToolCall(id: "chats", name: "list_chats", arguments: .object([:]))),
            descriptor: AgentToolDescriptor(
                name: "list_chats", summary: "List chats", inputSchema: .object([:]), target: .local,
                approvalPolicy: .approve,
                presentation: .init(
                    symbol: "bubble.left.and.bubble.right", activity: .semanticLabel(.chats), output: .json,
                    presenterID: "builtin.list_chats", actionKind: .list)))
        card.state = .completed
        card.result = AgentToolResult(
            callID: "chats",
            content: AgentJSONValue.object([
                "chats": .array([
                    .object([
                        "chat_id": .string(destinationID.uuidString), "title": .string("Linked chat"),
                        "status": .string("completed"),
                    ])
                ])
            ]).encodedString)
        presentation.disclosures.toggleDisclosure(.tool(card.id))
        var message = ChatMessage(role: .assistant, text: "**Working**")
        var group = AgentWorkGroup(
            run: AgentRunSummary(id: runID, state: .running, startedAt: .now),
            items: [.message(message), .tool(card)],
            orderedAt: .now, appearsAfterAnswer: false)
        let entry = TranscriptEntry(id: runID, content: .work(group))
        var navigations: [UUID] = []
        let actions = TranscriptListActions(navigateChat: { navigations.append($0) })
        update(
            coordinator, list, entries: [entry], presentation: presentation, actions: actions,
            chatDestinations: [destinationID: "Linked chat"])
        await settleResize(list)
        let row = try #require(list.rowView(for: runID))
        let markdown = try #require(descendant(in: row, ofType: MarkdownTextView.self))
        let link = try #require(descendants(in: row, ofType: NSButton.self).first { $0.title == "Linked chat" })
        let destinationStates: [[UUID: String]] = [[:], [destinationID: "Restored"]]
        for destinations in destinationStates {
            update(
                coordinator, list, entries: [entry], presentation: presentation, actions: actions,
                chatDestinations: destinations)
            #expect(list.rowView(for: runID) === row)
            #expect(descendant(in: row, ofType: MarkdownTextView.self) === markdown)
            #expect(descendants(in: row, ofType: NSButton.self).first { $0.title == "Linked chat" } === link)
            #expect(link.isEnabled == (destinations[destinationID] != nil))
        }
        message.text += " with another delta"
        group.items = [.message(message), .tool(card)]
        let revised = TranscriptEntry(id: runID, content: .work(group))
        update(
            coordinator, list, entries: [revised], presentation: presentation, actions: actions,
            chatDestinations: [destinationID: "Restored"])
        #expect(list.content == [revised])
        #expect(descendant(in: row, ofType: MarkdownTextView.self) === markdown)
        #expect(descendants(in: row, ofType: NSButton.self).first { $0.title == "Linked chat" } === link)
        update(coordinator, list, entries: [revised], presentation: presentation, actions: actions)
        #expect(!link.isEnabled, "Reused nested tool controls must retain their interaction binding")
        update(
            coordinator, list, entries: [revised], presentation: presentation, actions: actions,
            chatDestinations: [destinationID: "Restored"])
        link.performClick(nil)
        #expect(navigations == [destinationID])

        group.items = [.message(message)]
        let removed = TranscriptEntry(id: runID, content: .work(group))
        update(
            coordinator, list, entries: [removed], presentation: presentation, actions: actions,
            chatDestinations: [destinationID: "Restored"])
        #expect(!link.isDescendant(of: row))
        update(coordinator, list, entries: [removed], presentation: presentation, actions: actions)
        #expect(link.isEnabled, "Detached controls must no longer receive interaction updates")
    }

    @Test
    func editingDraftRefreshPreservesTextViewSelectionAndMarkedText() throws {
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        list.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let presentation = TranscriptPresentationState()
        let id = UUID()
        let entry = user(id: id, text: "Original text")
        presentation.beginEditingMessage(id, text: "Original text")
        update(coordinator, list, entries: [entry], presentation: presentation)
        let row = try #require(list.rowView(for: id))
        let editor = try #require(descendant(in: row, identifier: "Transcript.UserEditorText") as? NSTextView)
        editor.string = "Draft text"
        editor.setSelectedRange(NSRange(location: 3, length: 2))
        editor.didChangeText()
        coordinator.refreshDisplayedRow(id, in: list)
        #expect(descendant(in: row, identifier: "Transcript.UserEditorText") === editor)
        #expect(editor.selectedRange() == NSRange(location: 3, length: 2))
        #expect(presentation.messageEditText(id) == "Draft text")
        editor.setMarkedText(
            "composition", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        let markedRange = editor.markedRange()
        coordinator.refreshDisplayedRow(id, in: list)
        #expect(descendant(in: row, identifier: "Transcript.UserEditorText") === editor)
        #expect(editor.hasMarkedText())
        #expect(editor.markedRange() == markedRange)
    }

    @Test
    func recyclingUserRowReleasesItsBubble() throws {
        weak var bubble: NSView?
        try autoreleasepool {
            let coordinator = TranscriptListView.Coordinator()
            let list = coordinator.makeListView()
            list.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
            let id = UUID()
            update(coordinator, list, entries: [user(id: id, text: "Release this bubble")])
            let row = try #require(list.rowView(for: id) as? TranscriptNativeRow)
            bubble = descendant(in: row, identifier: "Transcript.UserBubble")
            #expect(bubble != nil)
            row.prepareForReuse()
        }
        #expect(bubble == nil)
    }

    @Test
    func actionOnlyUpdateUsesCurrentHandlersWithoutReplacingTheEditor() throws {
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        list.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let presentation = TranscriptPresentationState()
        let id = UUID()
        let entry = user(id: id, text: "Original")
        presentation.beginEditingMessage(id, text: "Revised")
        var oldCalls = 0
        var newCalls: [String] = []
        update(
            coordinator, list, entries: [entry], presentation: presentation,
            actions: .init(editUserMessage: { _, _ in oldCalls += 1 }))
        let row = try #require(list.rowView(for: id))
        let editor = try #require(descendant(in: row, identifier: "Transcript.UserEditorText"))
        let send = try #require(descendant(in: row, identifier: "Transcript.UserEditorSend") as? NSButton)
        update(
            coordinator, list, entries: [entry], presentation: presentation,
            actions: .init(editUserMessage: { _, text in newCalls.append(text) }))
        #expect(descendant(in: row, identifier: "Transcript.UserEditorText") === editor)
        send.performClick(nil)
        #expect(oldCalls == 0)
        #expect(newCalls == ["Revised"])
        coordinator.suspend()
        send.performClick(nil)
        #expect(newCalls == ["Revised"])
    }

    @Test
    func streamingWorkReusesUnchangedToolAndMarkdownChildren() throws {
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        list.frame = CGRect(x: 0, y: 0, width: 600, height: 1200)
        let presentation = TranscriptPresentationState()
        let runID = UUID()
        var message = ChatMessage(role: .assistant, text: "First", isStreaming: true)
        let card = AgentToolCard(
            invocation: AgentToolInvocation(
                runID: runID, call: AgentToolCall(id: "tool", name: "lookup", arguments: .object([:]))),
            descriptor: AgentToolDescriptor(
                name: "lookup", summary: "lookup", inputSchema: .object([:]), target: .local, approvalPolicy: .approve)
        )
        var group = AgentWorkGroup(
            run: AgentRunSummary(id: runID, state: .running, startedAt: .now),
            items: [.message(message), .tool(card)], orderedAt: .now, appearsAfterAnswer: false)
        update(
            coordinator, list, entries: [TranscriptEntry(id: runID, content: .work(group))], presentation: presentation)
        let row = try #require(list.rowView(for: runID))
        let markdown = try #require(descendant(in: row, ofType: MarkdownTextView.self))
        let headers = descendants(in: row, ofType: NSControl.self).filter {
            String(describing: type(of: $0)) == "NativeDisclosureHeader"
        }
        #expect(headers.count == 2)
        message.text += " more streamed text"
        group.items = [.message(message), .tool(card)]
        update(
            coordinator, list, entries: [TranscriptEntry(id: runID, content: .work(group))], presentation: presentation)
        #expect(descendant(in: row, ofType: MarkdownTextView.self) === markdown)
        let updatedHeaders = descendants(in: row, ofType: NSControl.self).filter {
            String(describing: type(of: $0)) == "NativeDisclosureHeader"
        }
        #expect(updatedHeaders.count == headers.count)
        #expect(zip(headers, updatedHeaders).allSatisfy { $0 === $1 })
    }

    @Test
    func remountRestartsWorkTitleClockWithoutAContentRevision() async throws {
        let coordinator = TranscriptListView.Coordinator()
        let list = coordinator.makeListView()
        let presentation = TranscriptPresentationState()
        let id = UUID()
        list.frame = CGRect(x: 0, y: 0, width: 600, height: 800)
        let group = AgentWorkGroup(
            run: AgentRunSummary(id: id, state: .running, startedAt: .now.addingTimeInterval(-3)),
            items: [], orderedAt: .now, appearsAfterAnswer: false
        )
        update(coordinator, list, entries: [TranscriptEntry(id: id, content: .work(group))], presentation: presentation)
        // Never order or activate this window; only exercise native attachment callbacks.
        let window = NSWindow(contentRect: list.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = list
        defer { window.contentView = nil }
        let row = try #require(list.rowView(for: id))
        let header = try #require(
            descendants(in: row, ofType: NSControl.self).first {
                String(describing: type(of: $0)) == "NativeDisclosureHeader"
            })
        let initial = header.accessibilityLabel()
        window.contentView = nil
        try await Task.sleep(for: .milliseconds(1100))
        window.contentView = list
        let remounted = header.accessibilityLabel()
        #expect(remounted != initial)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(header.accessibilityLabel() != remounted)
    }

    @Test
    func resizingUnchangedMessagesReflowsMountedContentAndMeasuredHeights() async throws {
        for isCompact in [false, true] {
            let coordinator = TranscriptListView.Coordinator()
            let presentation = TranscriptPresentationState()
            let listView = coordinator.makeListView()
            let id = UUID()
            let entry = assistant(
                id: id, text: String(repeating: "A transcript paragraph must wrap at the current width. ", count: 16)
            )
            listView.frame = CGRect(x: 0, y: 0, width: 900, height: 1_200)
            update(coordinator, listView, entries: [entry], presentation: presentation, isCompact: isCompact)
            await settleResize(listView)
            let row = try #require(listView.rowView(for: id))
            let markdown = try #require(descendant(in: row, identifier: "Transcript.AssistantMarkdown"))
            let segment = try #require(descendant(in: row, ofType: MarkdownTextView.self))
            let wideHeight = listView.rectForRow(with: id).height
            let wideWidth = markdown.bounds.width

            listView.frame.size.width = 360
            await settleResize(listView)

            #expect(listView.rowView(for: id) === row)
            #expect(descendant(in: row, ofType: MarkdownTextView.self) === segment)
            #expect(abs(markdown.bounds.width - (360 - (isCompact ? 24 : 32))) <= 1)
            #expect(listView.rectForRow(with: id).height > wideHeight)
            #expect(segment.bounds.height > 1)

            listView.frame.size.width = 900
            await settleResize(listView)

            #expect(abs(markdown.bounds.width - wideWidth) <= 1)
            #expect(abs(listView.rectForRow(with: id).height - wideHeight) <= 1)
        }
    }

    @Test
    func resizingUserBubblesAndStreamingMessagesDoesNotRequireANewSnapshot() async throws {
        let coordinator = TranscriptListView.Coordinator()
        let presentation = TranscriptPresentationState()
        let listView = coordinator.makeListView()
        let userID = UUID()
        let assistantID = UUID()
        let entries = [
            user(id: userID, text: String(repeating: "A long user message. ", count: 20)),
            streamingAssistant(id: assistantID, text: String(repeating: "Streaming prose reflows. ", count: 20)),
        ]
        listView.frame = CGRect(x: 0, y: 0, width: 900, height: 1_200)
        update(coordinator, listView, entries: entries, presentation: presentation, isCompact: false)
        await settleResize(listView)
        let wideHeight = listView.rectForRow(with: assistantID).height

        listView.frame.size.width = 360
        await settleResize(listView)

        let userRow = try #require(listView.rowView(for: userID))
        let bubble = try #require(descendant(in: userRow, identifier: "Transcript.UserBubble"))
        #expect(bubble.bounds.width <= 360 - 32 - Metrics.Chat.gutter + 1)
        #expect(listView.rectForRow(with: assistantID).height > wideHeight)
        #expect(listView.rectForRow(with: assistantID).minY == listView.rectForRow(with: userID).maxY)
    }

    private func settleResize(_ listView: TranscriptListView.NativeListView) async {
        listView.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        listView.layoutSubtreeIfNeeded()
    }

    @Test
    func ordinaryScrollingDoesNotReconfigureMessageWidths() async throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let id = UUID()
        let entries =
            [user(id: id, text: "Keep this visible bubble mounted.")]
            + (0..<12).map { _ in TranscriptEntry(id: UUID(), content: .empty) }
        listView.frame = CGRect(x: 0, y: 0, width: 360, height: 220)
        update(coordinator, listView, entries: entries)
        listView.setContentOffset(.zero, animated: false)
        await settleResize(listView)
        let row = try #require(listView.rowView(for: id))
        let bubble = try #require(descendant(in: row, identifier: "Transcript.UserBubble"))

        listView.setContentOffset(CGPoint(x: 0, y: 12), animated: false)
        await settleResize(listView)

        #expect(descendant(in: row, identifier: "Transcript.UserBubble") === bubble)
    }

    @Test
    func resizingMarkdownRecomputesCodeAndTableOverflow() async throws {
        let coordinator = TranscriptListView.Coordinator()
        let presentation = TranscriptPresentationState()
        let listView = coordinator.makeListView()
        let id = UUID()
        let text = """
            | Key | Value | Previous value |
            | --- | --- | --- |
            | result | \(String(repeating: "W", count: 64)) | \(String(repeating: "W", count: 64)) |

            ```swift
            let result = "\(String(repeating: "w", count: 80))"
            ```
            """
        listView.frame = CGRect(x: 0, y: 0, width: 900, height: 800)
        update(
            coordinator, listView, entries: [assistant(id: id, text: text)], presentation: presentation,
            isCompact: false)
        await settleResize(listView)
        let row = try #require(listView.rowView(for: id))
        let segment = try #require(descendant(in: row, ofType: MarkdownTextView.self))

        listView.frame.size.width = 360
        await settleResize(listView)
        let narrowScrollers = descendants(in: segment, ofType: NSScrollView.self)
        #expect(narrowScrollers.count == 2)
        #expect(narrowScrollers.allSatisfy { !$0.hasHorizontalScroller })
        #expect(narrowScrollers.allSatisfy { $0.contentView.bounds.width <= 328 })
        for scroller in narrowScrollers {
            #expect((scroller.documentView?.frame.width ?? 0) > scroller.contentView.bounds.width)
        }

        listView.frame.size.width = 900
        await settleResize(listView)
        #expect(descendant(in: row, ofType: MarkdownTextView.self) === segment)
        #expect(
            descendants(in: segment, ofType: NSScrollView.self).allSatisfy {
                $0.contentView.bounds.width > 328
            })
    }

    @Test
    func richTranscriptDoesNotInstallAPerFrameRowAnimator() {
        let listView = TranscriptListView.Coordinator().makeListView()
        #expect(listView.rowAnimator == nil)
    }

    @Test
    func visibleCompletedWorkDefersCollapseUntilItLeavesTheViewport() async {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let presentation = TranscriptPresentationState()
        let id = UUID()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 180)
        let tail = (0..<12).map { _ in TranscriptEntry(id: UUID(), content: .empty) }

        update(
            coordinator, listView,
            entries: [work(id: id, state: .running)] + tail,
            presentation: presentation
        )
        listView.layoutSubtreeIfNeeded()
        listView.setContentOffset(.zero, animated: false)
        listView.layoutSubtreeIfNeeded()
        update(
            coordinator, listView,
            entries: [work(id: id, state: .completed)] + tail,
            presentation: presentation
        )

        #expect(presentation.disclosures.isExpanded(.work(id)))
        #expect(presentation.disclosures.hasPendingAutoCollapse(id))

        let expandedFrame = listView.rectForRow(with: id)
        listView.setContentOffset(
            CGPoint(x: 0, y: expandedFrame.maxY - 1),
            animated: false
        )
        listView.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(presentation.disclosures.isExpanded(.work(id)), "one visible point must defer collapse")

        listView.setContentOffset(
            CGPoint(x: 0, y: listView.maximumContentOffset.y),
            animated: false
        )
        listView.layoutSubtreeIfNeeded()
        await Task.yield()

        #expect(!presentation.disclosures.isExpanded(.work(id)))
        #expect(!presentation.disclosures.hasPendingAutoCollapse(id))
    }

    @Test
    func streamingUpdateKeepsTheMountedAssistantRowIdentity() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let id = UUID()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
        let first = TranscriptEntry(
            id: id,
            content: .assistant(
                ChatMessage(id: id, role: .assistant, text: "First", isStreaming: true),
                canFork: false
            )
        )
        update(coordinator, listView, entries: [first])
        let mounted = try #require(listView.rowView(for: id))

        let second = TranscriptEntry(
            id: id,
            content: .assistant(
                ChatMessage(id: id, role: .assistant, text: "First delta", isStreaming: true),
                canFork: false
            )
        )
        update(coordinator, listView, entries: [second])

        #expect(listView.rowView(for: id) === mounted)
    }

    @Test
    func everyStreamingRevisionIsAppliedImmediately() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let id = UUID()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
        let first = streamingAssistant(id: id, text: "0")
        update(coordinator, listView, entries: [first])

        for revision in 1...20 {
            update(
                coordinator,
                listView,
                entries: [streamingAssistant(id: id, text: String(revision))]
            )
            let latest = try #require(listView.content.first)
            guard case .assistant(let message, _) = latest.content else {
                Issue.record("Expected the assistant row")
                return
            }
            #expect(message.text == String(revision))
        }
    }

    @Test
    func userBubbleUsesMarkdownHugsShortContentAndKeepsTheTrailingGutter() throws {
        for isCompact in [true, false] {
            let coordinator = TranscriptListView.Coordinator()
            let listView = coordinator.makeListView()
            let id = UUID()
            listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)

            update(
                coordinator,
                listView,
                entries: [user(id: id, text: "**Hi**")],
                isCompact: isCompact
            )
            listView.layoutSubtreeIfNeeded()

            let row = try #require(listView.rowView(for: id))
            let shortBubble = try #require(
                descendant(in: row, identifier: "Transcript.UserBubble")
            )
            let shortMarkdown = try #require(
                descendant(in: row, identifier: "Transcript.UserMarkdown")
            )
            let shortFrame = row.convert(shortBubble.bounds, from: shortBubble)
            let horizontalInset = isCompact ? Metrics.Space.l : Metrics.Space.xl
            #expect(abs(shortFrame.maxX - (row.bounds.maxX - horizontalInset)) <= 1)
            #expect(shortFrame.width < row.bounds.width / 2)
            #expect(
                abs(shortBubble.bounds.width - shortMarkdown.bounds.width - Metrics.Space.l * 2)
                    <= 1
            )
            #expect(
                abs(shortBubble.bounds.height - shortMarkdown.bounds.height - Metrics.Space.m * 2)
                    <= 1
            )

            update(
                coordinator,
                listView,
                entries: [
                    user(
                        id: id,
                        text: String(repeating: "A long Markdown sentence that wraps. ", count: 30)
                    )
                ],
                isCompact: isCompact
            )
            listView.layoutSubtreeIfNeeded()

            let longBubble = try #require(
                descendant(in: row, identifier: "Transcript.UserBubble")
            )
            let longFrame = row.convert(longBubble.bounds, from: longBubble)
            let gutter = isCompact ? Metrics.Chat.compactGutter : Metrics.Chat.gutter
            let maximumWidth = row.bounds.width - horizontalInset * 2 - gutter
            #expect(longFrame.width > shortFrame.width)
            #expect(longFrame.width <= maximumWidth + 1)
            #expect(abs(longFrame.maxX - (row.bounds.maxX - horizontalInset)) <= 1)
        }
    }

    @Test
    func terminalSuggestionUsesUpstreamCodeWithActionsAndRiskBelow() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
        let suggestion = SuggestedCommand(command: "pwd")
        var deliveries: [(String, Bool)] = []
        update(
            coordinator, listView,
            entries: [.init(id: suggestion.id, content: .command(suggestion))],
            showsTerminalActions: true,
            actions: .init(
                canDeliverCommand: { true },
                deliverCommand: { deliveries.append(($0, $1)) }
            )
        )
        listView.layoutSubtreeIfNeeded()

        let row = try #require(listView.rowView(for: suggestion.id))
        let card = try #require(descendant(in: row, identifier: "Transcript.CommandCard"))
        let content = try #require(descendant(in: card, identifier: "Transcript.CommandCardContent") as? NSStackView)
        let details = try #require(descendant(in: card, identifier: "Transcript.CommandCardDetails") as? NSStackView)
        let code = try #require(descendant(in: card, identifier: "Transcript.CommandCardCommand"))
        let markdown = try #require(descendant(in: code, ofType: MarkdownTextView.self))
        guard case .codeBlock(let title, let command)? = markdown.content.blocks.first else {
            Issue.record("expected the suggested command in an upstream code block")
            return
        }
        #expect(title == "Suggested Command")
        #expect(command == "pwd")
        let codeButtons = descendants(in: markdown, ofType: NSButton.self)
        for selector in ["handleCopy:", "handleExpand:"] {
            let button = try #require(codeButtons.first { $0.action.map(NSStringFromSelector) == selector })
            #expect(button.target != nil && button.isEnabled && !button.isHidden)
        }
        #expect(descendants(in: markdown, ofType: NSScrollView.self).allSatisfy { !$0.hasHorizontalScroller })

        let footer = try #require(descendant(in: card, identifier: "Transcript.CommandCardActions") as? NSStackView)
        #expect(content.arrangedSubviews.first === code)
        #expect(content.arrangedSubviews.last === details)
        #expect(details.arrangedSubviews.last === footer)
        #expect(details.arrangedSubviews.count == 1)
        #expect(descendant(in: card, identifier: "Transcript.CommandCardExplanation") == nil)
        #expect(descendant(in: footer, identifier: "Transcript.CommandCardRiskBadge") != nil)
        let insert = try #require(descendant(in: footer, identifier: "Transcript.CommandCardInsert") as? NSButton)
        let run = try #require(descendant(in: footer, identifier: "Transcript.CommandCardRun") as? NSButton)
        insert.performClick(nil)
        run.performClick(nil)
        #expect(deliveries.map(\.0) == ["pwd", "pwd"])
        #expect(deliveries.map(\.1) == [false, true])
    }

    @Test
    func nativeTranscriptProminentButtonsInvertTheirForegroundWithAppearance() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let presentation = TranscriptPresentationState()
        let userID = UUID()
        let plan = AgentPlan(
            title: "Implementation plan",
            body: "Apply the requested change.",
            scratchPath: "/tmp/plan.md"
        )
        let commandID = UUID()
        listView.appearance = NSAppearance(named: .aqua)
        listView.frame = CGRect(x: 0, y: 0, width: 520, height: 2_000)
        presentation.beginEditingMessage(userID, text: "Edited message")

        update(
            coordinator,
            listView,
            entries: [
                user(id: userID, text: "Original message"),
                TranscriptEntry(
                    id: plan.id,
                    content: .plan(AgentPlanCard(plan: plan))
                ),
                TranscriptEntry(
                    id: commandID,
                    content: .command(
                        SuggestedCommand(
                            id: commandID,
                            command: "pwd"
                        )
                    )
                ),
            ],
            presentation: presentation,
            isCompact: false,
            showsTerminalActions: true,
            actions: .init(canDeliverCommand: { true })
        )
        listView.layoutSubtreeIfNeeded()

        let buttonLocations = [
            (userID, "Transcript.UserEditorSend"),
            (plan.id, "Transcript.PlanImplement"),
            (commandID, "Transcript.CommandCardRun"),
        ]
        let buttons = try buttonLocations.map { rowID, identifier in
            let row = try #require(listView.rowView(for: rowID))
            return try #require(descendant(in: row, identifier: identifier) as? NSButton)
        }

        for button in buttons {
            try expectProminentForeground(button, component: 1)
        }

        listView.appearance = NSAppearance(named: .darkAqua)
        listView.layoutSubtreeIfNeeded()

        for button in buttons {
            try expectProminentForeground(button, component: 0)
        }
    }

    @Test
    func userImagesAndChipsSitOutsideAndAboveTheTextBubble() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
        let id = UUID()
        let data = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL7WQAAAABJRU5ErkJggg=="
            ))
        let attachment = AgentImageAttachment(
            label: "Dropped image",
            mimeType: "image/png",
            data: data,
            pixelWidth: 16,
            pixelHeight: 16
        )
        let chip = ContextChipReference(
            id: attachment.id,
            kind: .image,
            label: attachment.label
        )
        let entry = TranscriptEntry(
            id: id,
            content: .user(
                ChatMessage(
                    id: id,
                    role: .user,
                    text: "what’s this",
                    contextChips: [chip],
                    images: [attachment]
                ),
                canEdit: false
            )
        )

        update(coordinator, listView, entries: [entry])
        listView.layoutSubtreeIfNeeded()

        let row = try #require(listView.rowView(for: id))
        let image = try #require(descendant(in: row, identifier: "Transcript.UserImage"))
        let chipView = try #require(descendant(in: row, identifier: "Transcript.UserChip"))
        let bubble = try #require(descendant(in: row, identifier: "Transcript.UserBubble"))
        #expect(!image.isDescendant(of: bubble))
        #expect(!chipView.isDescendant(of: bubble))

        let imageFrame = row.convert(image.bounds, from: image)
        let chipFrame = row.convert(chipView.bounds, from: chipView)
        let bubbleFrame = row.convert(bubble.bounds, from: bubble)
        if row.isFlipped {
            #expect(imageFrame.maxY <= chipFrame.minY)
            #expect(chipFrame.maxY <= bubbleFrame.minY)
        } else {
            #expect(imageFrame.minY >= chipFrame.maxY)
            #expect(chipFrame.minY >= bubbleFrame.maxY)
        }
        #expect(abs(imageFrame.maxX - bubbleFrame.maxX) <= 1)
        #expect(abs(chipFrame.maxX - bubbleFrame.maxX) <= 1)
    }

    @Test
    func userImageUsesAReliableSquareCenterCropForEverySourceRatio() throws {
        let data = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL7WQAAAABJRU5ErkJggg=="
            ))
        for (pixelWidth, pixelHeight) in [(400, 200), (200, 400)] {
            let coordinator = TranscriptListView.Coordinator()
            let listView = coordinator.makeListView()
            listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
            let id = UUID()
            let attachment = AgentImageAttachment(
                label: "preview.png",
                mimeType: "image/png",
                data: data,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
            let entry = TranscriptEntry(
                id: id,
                content: .user(
                    ChatMessage(
                        id: id,
                        role: .user,
                        text: "preview",
                        images: [attachment]
                    ),
                    canEdit: false
                )
            )

            update(
                coordinator,
                listView,
                entries: [entry],
                isCompact: false
            )
            listView.layoutSubtreeIfNeeded()

            let row = try #require(listView.rowView(for: id))
            let image = try #require(
                descendant(in: row, identifier: "Transcript.UserImage")
            )
            let preview = try #require(
                descendant(in: image, identifier: "Transcript.UserImagePreview")
            )
            #expect(image.bounds.width == Metrics.Chat.imageTile)
            #expect(image.bounds.height == Metrics.Chat.imageTile)
            #expect(preview.bounds.width == preview.bounds.height)
            #expect(preview.layer?.contentsGravity == .resizeAspectFill)
            #expect(preview.layer?.masksToBounds == true)
        }
    }

    @Test
    func userEditorExpandsFromAShortBubbleAndGrowsWithItsDraft() throws {
        for isCompact in [true, false] {
            let coordinator = TranscriptListView.Coordinator()
            let listView = coordinator.makeListView()
            let presentation = TranscriptPresentationState()
            let id = UUID()
            listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
            let entry = user(id: id, text: "Hi")

            update(
                coordinator,
                listView,
                entries: [entry],
                presentation: presentation,
                isCompact: isCompact
            )
            listView.layoutSubtreeIfNeeded()
            let row = try #require(listView.rowView(for: id))
            let restingBubble = try #require(
                descendant(in: row, identifier: "Transcript.UserBubble")
            )
            let restingWidth = restingBubble.bounds.width

            presentation.beginEditingMessage(id, text: "Hi")
            coordinator.refreshDisplayedRow(id, in: listView)
            listView.layoutSubtreeIfNeeded()

            let shortEditor = try #require(
                descendant(in: row, identifier: "Transcript.UserEditor")
            )
            let shortScroll = try #require(
                descendant(in: row, identifier: "Transcript.UserEditorScroll")
            )
            let editingBubble = try #require(
                descendant(in: row, identifier: "Transcript.UserBubble")
            )
            let minimumEditorWidth: CGFloat = isCompact ? 160 : 200
            #expect(shortEditor.bounds.width >= minimumEditorWidth)
            #expect(editingBubble.bounds.width > restingWidth)
            #expect(
                abs(editingBubble.bounds.width - shortEditor.bounds.width - Metrics.Space.l * 2)
                    <= 1
            )
            let shortHeight = shortScroll.bounds.height
            #expect(shortHeight >= 44)

            presentation.setMessageEditText(
                (1...12).map { "Expanded line \($0)" }.joined(separator: "\n"),
                for: id
            )
            coordinator.refreshDisplayedRow(id, in: listView)
            listView.layoutSubtreeIfNeeded()

            let tallScroll = try #require(
                descendant(in: row, identifier: "Transcript.UserEditorScroll")
            )
            #expect(tallScroll === shortScroll)
            #expect(tallScroll.bounds.height > shortHeight)
            #expect(tallScroll.bounds.height <= 160)
        }
    }

    @Test
    func streamingTextHasNoSupplementalCaretRowAndEmptyTextKeepsWorkingActivity() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let id = UUID()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)

        update(coordinator, listView, entries: [streamingAssistant(id: id, text: "Hello")])
        listView.layoutSubtreeIfNeeded()

        let row = try #require(listView.rowView(for: id))
        let markdown = try #require(
            descendant(in: row, identifier: "Transcript.AssistantMarkdown")
        )
        let markdownFrame = row.convert(markdown.bounds, from: markdown)
        #expect(abs(markdownFrame.maxY - row.bounds.maxY) <= 1)
        #expect(descendant(in: row, identifier: "Transcript.WorkingActivity") == nil)

        update(
            coordinator,
            listView,
            entries: [streamingAssistant(id: id, text: "")]
        )
        listView.layoutSubtreeIfNeeded()

        #expect(descendant(in: row, identifier: "Transcript.WorkingActivity") != nil)
    }

    @Test
    func workingActivityUsesAFullBoundsMovingNotchMask() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let id = UUID()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)

        update(
            coordinator,
            listView,
            entries: [streamingAssistant(id: id, text: "")],
            reduceMotion: false
        )
        listView.layoutSubtreeIfNeeded()

        let row = try #require(listView.rowView(for: id))
        let activity = try #require(
            descendant(in: row, identifier: "Transcript.WorkingActivity")
        )
        activity.layoutSubtreeIfNeeded()
        let mask = try #require(activity.layer?.mask)
        #expect(mask.frame == activity.bounds)
        #expect(mask.animation(forKey: "scan") != nil)
    }

    @Test(arguments: [360.0, 900.0])
    func compactToolExpansionKeepsBothButtonTitlesLeftAligned(width: Double) throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let presentation = TranscriptPresentationState()
        let runID = UUID()
        let invocation = AgentToolInvocation(
            runID: runID,
            call: AgentToolCall(id: "read", name: "sftp_read", arguments: .object([:]))
        )
        var card = AgentToolCard(
            invocation: invocation,
            descriptor: AgentToolDescriptor(
                name: "sftp_read", summary: "Read a file", inputSchema: .object([:]),
                target: .host, approvalPolicy: .approve,
                presentation: .init(
                    symbol: "doc", activity: .semanticArgument(key: "path", fallback: .remoteFile),
                    presenterID: "builtin.sftp_read")
            )
        )
        card.state = .running
        card.result = AgentToolResult(
            callID: "read",
            content: AgentJSONValue.object([
                "path": .string("/tmp/report.txt"),
                "content": .string((1...20).map { "Line \($0)" }.joined(separator: "\n")),
                "bytes": .number(150),
            ]).encodedString
        )
        card.result?.truncateMarker = AgentTruncateMarker.render(ranges: [1...20], totalLines: 100)
        presentation.disclosures.toggleDisclosure(.tool(card.id))
        let entry = TranscriptEntry(
            id: runID,
            content: .work(
                AgentWorkGroup(
                    run: AgentRunSummary(id: runID, state: .running, startedAt: .now),
                    items: [.tools(AgentToolBatch(cards: [card], runID: runID, reasoning: nil))],
                    orderedAt: .now, anchorMessageID: nil, appearsAfterAnswer: false,
                    activeReasoningBlockID: nil
                ))
        )
        listView.frame = CGRect(x: 0, y: 0, width: width, height: 1_200)
        update(coordinator, listView, entries: [entry], presentation: presentation)
        listView.layoutSubtreeIfNeeded()

        for title in ["Show more", "Show less"] {
            let row = try #require(listView.rowView(for: runID))
            let button = try #require(descendant(in: row, identifier: "AssistantTool.More") as? NSButton)
            let details = try #require(descendant(in: row, identifier: "AssistantTool.CompactDetails") as? NSStackView)
            let notice = try #require(descendant(in: details, identifier: "AssistantTool.TruncationNotice"))
            #expect(button.title == title)
            #expect(button.alignment == .left)
            #expect(abs(details.convert(button.bounds, from: button).minX) <= 1)
            #expect(
                try #require(details.arrangedSubviews.firstIndex(of: notice))
                    < #require(details.arrangedSubviews.firstIndex(of: button)))
            button.performClick(nil)
            coordinator.refreshDisplayedRow(runID, in: listView)
            listView.layoutSubtreeIfNeeded()
        }
        #expect(!presentation.disclosures.isExpanded(.toolDetail(card.id)))
    }

    @Test
    func singleRunningToolTitleStillInstallsTheScanningMask() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let runID = UUID()
        let invocation = AgentToolInvocation(
            runID: runID,
            call: AgentToolCall(
                id: "call", name: "lookup", arguments: .object([:])
            )
        )
        var card = AgentToolCard(
            invocation: invocation,
            descriptor: AgentToolDescriptor(
                name: "lookup", summary: "lookup", inputSchema: .object([:]),
                target: .local, approvalPolicy: .approve
            )
        )
        card.state = .running
        let entry = TranscriptEntry(
            id: runID,
            content: .work(
                AgentWorkGroup(
                    run: AgentRunSummary(
                        id: runID, state: .running, startedAt: .now
                    ),
                    items: [
                        .tools(
                            AgentToolBatch(
                                cards: [card], runID: runID, reasoning: nil
                            ))
                    ],
                    orderedAt: .now,
                    anchorMessageID: nil,
                    appearsAfterAnswer: false,
                    activeReasoningBlockID: nil
                ))
        )
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)

        update(
            coordinator,
            listView,
            entries: [entry],
            reduceMotion: false
        )
        listView.layoutSubtreeIfNeeded()

        let row = try #require(listView.rowView(for: runID))
        let title = try #require(
            descendant(in: row, identifier: "Transcript.ScanningTitle")
        )
        #expect(title.layer?.mask?.animation(forKey: "scan") != nil)
    }

    @Test
    func messageRowsTrackMouseMovementAcrossContentGapAndSideWhitespace() throws {
        for isCompact in [true, false] {
            for entry in [
                user(id: UUID(), text: "User message"),
                assistant(id: UUID(), text: "Assistant message"),
            ] {
                let coordinator = TranscriptListView.Coordinator()
                let listView = coordinator.makeListView()
                listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)

                update(
                    coordinator,
                    listView,
                    entries: [entry],
                    isCompact: isCompact
                )
                listView.layoutSubtreeIfNeeded()

                let row = try #require(listView.rowView(for: entry.id))
                let actions = try #require(
                    descendant(in: row, identifier: "Transcript.MessageActions")
                )
                let contentIdentifier =
                    entry.kind == .user
                    ? "Transcript.UserBubble" : "Transcript.AssistantMarkdown"
                let content = try #require(
                    descendant(in: row, identifier: contentIdentifier)
                )
                let contentFrame = row.convert(content.bounds, from: content)
                let actionsFrame = row.convert(actions.bounds, from: actions)

                row.updateTrackingAreas()
                let tracking = try #require(
                    row.trackingAreas.first { $0.options.contains(.mouseMoved) }
                )
                #expect(tracking.options.contains(.inVisibleRect))
                #expect(row.bounds.width == listView.bounds.width)
                #expect(contentFrame.minX > row.bounds.minX)
                #expect(contentFrame.maxX < row.bounds.maxX)
                #expect(
                    abs(
                        actionsFrame.minY - contentFrame.maxY
                            - Metrics.Chat.blockSpacing
                    ) <= 1
                )

                let gap = CGPoint(x: row.bounds.midX, y: contentFrame.maxY + 1)
                row.mouseMoved(with: try #require(pointerEvent(at: gap)))
                #expect(actions.alphaValue == 1)

                row.mouseExited(with: try #require(pointerEvent()))
                #expect(actions.alphaValue == 0)
            }
        }
    }

    @Test
    func hoverSurvivesTheRefreshThatAddsCompletedMessageActions() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let presentation = TranscriptPresentationState()
        let id = UUID()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)

        update(
            coordinator,
            listView,
            entries: [streamingAssistant(id: id, text: "Working")],
            presentation: presentation
        )
        let row = try #require(listView.rowView(for: id) as? TranscriptAssistantRow)
        let event = try #require(pointerEvent())
        row.mouseEntered(with: event)

        update(
            coordinator,
            listView,
            entries: [assistant(id: id, text: "Finished")],
            presentation: presentation
        )
        listView.layoutSubtreeIfNeeded()

        let actions = try #require(
            descendant(in: row, identifier: "Transcript.MessageActions")
        )
        #expect(actions.alphaValue == 1)

        row.mouseExited(with: event)
        #expect(actions.alphaValue == 0)
        row.mouseEntered(with: event)
        #expect(actions.alphaValue == 1)
    }

    @Test
    func preparingAHoveredRowForReuseClearsItsActionVisibility() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let id = UUID()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)

        update(coordinator, listView, entries: [assistant(id: id, text: "Finished")])
        let row = try #require(listView.rowView(for: id) as? TranscriptAssistantRow)
        let actions = try #require(
            descendant(in: row, identifier: "Transcript.MessageActions")
        )
        row.mouseEntered(with: try #require(pointerEvent()))
        #expect(actions.alphaValue == 1)

        row.prepareForReuse()

        #expect(actions.alphaValue == 0)
    }

    @Test(arguments: [false, true], [false, true])
    func markdownRendersOneDocumentWithoutAddingScrollbars(isUser: Bool, overflows: Bool) throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let id = UUID()
        listView.frame = CGRect(x: 0, y: 0, width: overflows ? 320 : 900, height: 1_200)
        let value = overflows ? String(repeating: "wide-content-", count: 24) : "short"
        let source = """
            Before the blocks.

            | Name | Value |
            | --- | --- |
            | table | \(value) |

            ```swift
            let value = "\(value)"
            ```

            ```bash
            echo "\(value)"
            ```

            After the blocks.
            """
        let entry = isUser ? user(id: id, text: source) : assistant(id: id, text: source)
        update(
            coordinator, listView, entries: [entry], showsTerminalActions: true,
            actions: .init(canDeliverCommand: { true })
        )
        listView.layoutSubtreeIfNeeded()

        let row = try #require(listView.rowView(for: id))
        let renderers = descendants(in: row, ofType: MarkdownTextView.self)
        #expect(renderers.count == 1)
        let markdown = try #require(renderers.first)
        #expect(markdown.content.blocks.count == 5)
        #expect(descendant(in: row, identifier: "Transcript.MarkdownShellRun") == nil)

        let scrollViews = descendants(in: markdown, ofType: NSScrollView.self)
        #expect(scrollViews.count == 3)
        #expect(scrollViews.allSatisfy { !$0.hasHorizontalScroller && !$0.hasVerticalScroller })
        #expect(descendants(in: markdown, ofType: NSScroller.self).isEmpty)

        if overflows {
            for scrollView in scrollViews {
                let documentView = try #require(scrollView.documentView)
                let maximumX = documentView.frame.width - scrollView.contentView.bounds.width
                #expect(maximumX > 0)
                scrollView.contentView.scroll(to: CGPoint(x: maximumX, y: 0))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                #expect(scrollView.contentView.bounds.minX > 0)
            }
        }
    }

    @Test
    func disclosureRefreshRebuildsTheVisiblePlanAndItsHeight() {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let presentation = TranscriptPresentationState()
        let plan = AgentPlan(
            title: "Implementation plan",
            body: String(repeating: "A detailed paragraph that wraps over several lines.\n\n", count: 24),
            scratchPath: "/tmp/plan.md"
        )
        let entry = TranscriptEntry(
            id: plan.id,
            content: .plan(AgentPlanCard(plan: plan))
        )
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 1_200)
        update(coordinator, listView, entries: [entry], presentation: presentation)
        listView.layoutSubtreeIfNeeded()
        let collapsedHeight = listView.rectForRow(with: plan.id).height

        presentation.disclosures.toggleDisclosure(.plan(plan.id))
        coordinator.refreshDisplayedRow(plan.id, in: listView)
        listView.layoutSubtreeIfNeeded()

        #expect(listView.rectForRow(with: plan.id).height > collapsedHeight)
    }

    @Test
    func nativeRowsUseTheirMeasuredHeights() {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let short = TranscriptEntry(id: UUID(), content: .empty)
        let tallID = UUID()
        let tall = TranscriptEntry(
            id: tallID,
            content: .assistant(
                ChatMessage(
                    id: tallID, role: .assistant,
                    text: String(repeating: "A wrapping transcript line. ", count: 80)
                ),
                canFork: false
            ),
            hasLeadingSpacing: true
        )
        listView.frame = CGRect(x: 0, y: 0, width: 320, height: 400)

        update(coordinator, listView, entries: [short, tall])
        listView.layoutSubtreeIfNeeded()

        let shortHeight = listView.rectForRow(with: short.id).height
        let tallHeight = listView.rectForRow(with: tall.id).height
        #expect(shortHeight > 0)
        #expect(tallHeight > 96)
        #expect(tallHeight > shortHeight)
    }

    @Test
    func explicitHeightRowsDoNotInstallVisibleMeasurementPrototypes() {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let item = TranscriptEntry(id: UUID(), content: .empty)
        listView.frame = CGRect(x: 0, y: 0, width: 320, height: 400)

        update(coordinator, listView, entries: [item])
        listView.layoutSubtreeIfNeeded()

        let rows = listView.subviews.compactMap { $0 as? ListRowView }
        #expect(rows.count == 1)
        #expect(rows.allSatisfy { !$0.isHidden })
    }

    @Test
    func aStableBlockGrowthRemeasuresBeforePlacingTheFollowingBlock() {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let growingID = UUID()
        let followingID = UUID()
        let short = assistant(id: growingID, text: "Short block")
        let tall = assistant(
            id: growingID,
            text: String(repeating: "Expanded work detail wraps over many lines. ", count: 80)
        )
        let following = TranscriptEntry(id: followingID, content: .empty)
        listView.frame = CGRect(x: 0, y: 0, width: 320, height: 1_200)

        update(coordinator, listView, entries: [short, following])
        let shortHeight = listView.rectForRow(with: growingID).height

        update(coordinator, listView, entries: [tall, following])
        listView.layoutSubtreeIfNeeded()

        let grownFrame = listView.rectForRow(with: growingID)
        let followingFrame = listView.rectForRow(with: followingID)
        #expect(grownFrame.height > shortHeight)
        #expect(followingFrame.minY == grownFrame.maxY)
        #expect(listView.rowView(for: growingID)?.placedFrame == grownFrame)
        #expect(listView.rowView(for: followingID)?.placedFrame == followingFrame)
    }

    @Test
    func followingTheBottomUsesTheRemeasuredBlockHeight() {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let growingID = UUID()
        let leading = TranscriptEntry(id: UUID(), content: .empty)
        let short = assistant(id: growingID, text: "Short block")
        let tall = assistant(
            id: growingID,
            text: String(repeating: "Expanded work detail wraps over many lines. ", count: 80)
        )
        listView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)

        update(coordinator, listView, entries: [leading, short])
        listView.scrollToBottom(animated: false)
        let oldMaximum = listView.maximumContentOffset.y

        update(coordinator, listView, entries: [leading, tall])

        #expect(listView.maximumContentOffset.y > oldMaximum)
        #expect(listView.contentOffset.y == listView.maximumContentOffset.y)
        let lastFrame = listView.rectForRow(with: growingID)
        #expect(lastFrame.maxY + listView.bottomInset == listView.contentSize.height)
    }

    @Test
    func blockGrowthDoesNotPullAReaderBackFromHistory() {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let growingID = UUID()
        let short = assistant(id: growingID, text: "Short block")
        let tall = assistant(
            id: growingID,
            text: String(repeating: "Expanded work detail wraps over many lines. ", count: 80)
        )
        let history = (0..<10).map { _ in
            TranscriptEntry(id: UUID(), content: .empty)
        }
        listView.frame = CGRect(x: 0, y: 0, width: 320, height: 180)

        update(coordinator, listView, entries: history + [short])
        listView.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
        listView.layoutSubtreeIfNeeded()
        let readerOffset = listView.contentOffset

        update(coordinator, listView, entries: history + [tall])

        #expect(listView.contentOffset == readerOffset)
        #expect(!listView.isScrolledToBottom(tolerance: Metrics.Space.l))
    }

    private func update(
        _ coordinator: TranscriptListView.Coordinator,
        _ listView: TranscriptListView.NativeListView,
        entries: [TranscriptEntry],
        presentation: TranscriptPresentationState = TranscriptPresentationState(),
        isCompact: Bool = true,
        showsTerminalActions: Bool = false,
        actions: TranscriptListActions = .init(),
        reduceMotion: Bool = true,
        colorScheme: ColorScheme = .light,
        isConversationStreaming: Bool = false,
        chatDestinations: [UUID: String] = [:]
    ) {
        coordinator.update(
            listView: listView,
            entries: entries,
            latestUserMessageID: nil,
            configuration: .init(
                isCompact: isCompact,
                showsTerminalActions: showsTerminalActions,
                isConversationStreaming: isConversationStreaming,
                chatDestinations: chatDestinations,
                locale: Locale(identifier: "en"),
                reduceMotion: reduceMotion,
                colorScheme: colorScheme
            ),
            actions: actions,
            presentation: presentation
        )
    }

    private func assistant(id: UUID, text: String) -> TranscriptEntry {
        TranscriptEntry(
            id: id,
            content: .assistant(
                ChatMessage(id: id, role: .assistant, text: text),
                canFork: false
            )
        )
    }

    private func user(id: UUID, text: String) -> TranscriptEntry {
        TranscriptEntry(
            id: id,
            content: .user(
                ChatMessage(id: id, role: .user, text: text),
                canEdit: false
            )
        )
    }

    private func streamingAssistant(id: UUID, text: String) -> TranscriptEntry {
        TranscriptEntry(
            id: id,
            content: .assistant(
                ChatMessage(id: id, role: .assistant, text: text, isStreaming: true),
                canFork: false
            )
        )
    }

    private func pointerEvent(at location: CGPoint = .zero) -> NSEvent? {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )
    }

    private func descendant(in root: NSView, identifier: String) -> NSView? {
        var queue = root.subviews
        while let view = queue.first {
            queue.removeFirst()
            if view.identifier?.rawValue == identifier { return view }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func descendant<View: NSView>(in root: NSView, ofType _: View.Type) -> View? {
        descendants(in: root, ofType: View.self).first
    }

    private func descendants<View: NSView>(in root: NSView, ofType _: View.Type) -> [View] {
        var result: [View] = []
        var queue = root.subviews
        while let view = queue.first {
            queue.removeFirst()
            if let match = view as? View { result.append(match) }
            queue.append(contentsOf: view.subviews)
        }
        return result
    }

    private func expectProminentForeground(_ button: NSButton, component: CGFloat) throws {
        let titleColor = try #require(
            button.attributedTitle.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        )
        let alternateTitleColor = try #require(
            button.attributedAlternateTitle.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        )
        for color in [try #require(button.contentTintColor), titleColor, alternateTitleColor] {
            let rgb = try #require(color.usingColorSpace(.deviceRGB))
            #expect(abs(rgb.redComponent - component) < 0.001)
            #expect(abs(rgb.greenComponent - component) < 0.001)
            #expect(abs(rgb.blueComponent - component) < 0.001)
            #expect(abs(rgb.alphaComponent - 1) < 0.001)
        }
    }

    private func work(id: UUID, state: AgentRunState) -> TranscriptEntry {
        let start = Date(timeIntervalSince1970: 1_000)
        return TranscriptEntry(
            id: id,
            content: .work(
                AgentWorkGroup(
                    run: AgentRunSummary(
                        id: id,
                        state: state,
                        startedAt: start,
                        finishedAt: state == .completed ? start.addingTimeInterval(2) : nil
                    ),
                    items: [
                        .message(
                            ChatMessage(
                                role: .assistant,
                                text: String(repeating: "Visible work detail. ", count: 20)
                            ))
                    ],
                    orderedAt: start,
                    anchorMessageID: nil,
                    appearsAfterAnswer: false,
                    activeReasoningBlockID: nil
                ))
        )
    }
}
