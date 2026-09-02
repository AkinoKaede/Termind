import AgentKit
import AppKit
import Foundation
import ListViewKit
import SwiftUI
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
    func aReaderToggleSurvivesDefaultStateTransitions() {
        let id = UUID()
        let state = TranscriptPresentationState()

        #expect(state.isExpanded(id, default: true))
        state.toggleDisclosure(id, default: true)
        #expect(!state.isExpanded(id, default: true))
        #expect(state.readerDidToggle(id))

        state.followDefault(true, for: id)
        #expect(!state.isExpanded(id, default: true))
    }

    @Test
    func untouchedDisclosureFollowsItsRuntimeDefault() {
        let id = UUID()
        let state = TranscriptPresentationState()

        state.followDefault(true, for: id)
        #expect(state.isExpanded(id))
        #expect(!state.readerDidToggle(id))
    }

    @Test
    func deferredAutoCollapseWaitsForTheCoordinatorAndRespectsReaderOverride() {
        let id = UUID()
        let state = TranscriptPresentationState()

        state.deferAutoCollapse(id)
        #expect(state.isExpanded(id))
        #expect(state.hasPendingAutoCollapse(id))
        #expect(state.completeAutoCollapse(id))
        #expect(!state.isExpanded(id))

        state.deferAutoCollapse(id)
        state.toggleDisclosure(id, default: true)
        #expect(!state.hasPendingAutoCollapse(id))
        #expect(!state.completeAutoCollapse(id))
    }

    @Test
    func reasoningDeadlineIsAbsoluteAndNewMarkdownResetsIt() {
        let id = UUID()
        let state = TranscriptPresentationState()
        let start = Date(timeIntervalSince1970: 1_000)

        let first = state.reasoningTitleDeadline(
            for: id, revision: "first", now: start
        )
        #expect(first == start.addingTimeInterval(3))
        #expect(
            state.reasoningTitleDeadline(
                for: id, revision: "first", now: start.addingTimeInterval(2)
            ) == first)
        #expect(
            state.reasoningTitleDeadline(
                for: id, revision: "second", now: start.addingTimeInterval(2)
            ) == start.addingTimeInterval(5))
    }

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

        #expect(presentation.isExpanded(id))
        #expect(presentation.hasPendingAutoCollapse(id))

        let expandedFrame = listView.rectForRow(with: id)
        listView.setContentOffset(
            CGPoint(x: 0, y: expandedFrame.maxY - 1),
            animated: false
        )
        listView.layoutSubtreeIfNeeded()
        await Task.yield()
        #expect(presentation.isExpanded(id), "one visible point must defer collapse")

        listView.setContentOffset(
            CGPoint(x: 0, y: listView.maximumContentOffset.y),
            animated: false
        )
        listView.layoutSubtreeIfNeeded()
        await Task.yield()

        #expect(!presentation.isExpanded(id))
        #expect(!presentation.hasPendingAutoCollapse(id))
    }

    @Test
    func entryKindsUseDedicatedReusableRowTypes() {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let empty = TranscriptEntry(id: UUID(), content: .empty)
        let assistant = assistant(id: UUID(), text: "Hello")
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)

        update(coordinator, listView, entries: [empty, assistant])
        listView.layoutSubtreeIfNeeded()

        #expect(listView.rowView(for: empty.id) is TranscriptEmptyRow)
        #expect(listView.rowView(for: assistant.id) is TranscriptAssistantRow)
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
    func userBubbleUsesASubtleAccentFillInLightAndDarkAppearances() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let coordinator = TranscriptListView.Coordinator()
            let listView = coordinator.makeListView()
            listView.appearance = NSAppearance(named: appearanceName)
            listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
            let id = UUID()

            update(coordinator, listView, entries: [user(id: id, text: "Hi")])
            listView.layoutSubtreeIfNeeded()

            let row = try #require(listView.rowView(for: id))
            let bubble = try #require(
                descendant(in: row, identifier: "Transcript.UserBubble")
            )
            bubble.updateLayer()
            let color = try #require(bubble.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
            #expect(abs(color.alphaComponent - 0.10) < 0.002)
        }
    }

    @Test
    func mountedTranscriptRefreshesWhenSystemAppearanceChanges() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 260)
        let id = UUID()
        let entry = user(id: id, text: "The same mounted row follows system appearance.")

        listView.appearance = NSAppearance(named: .aqua)
        update(
            coordinator,
            listView,
            entries: [entry],
            colorScheme: .light
        )
        listView.layoutSubtreeIfNeeded()
        let lightRow = try #require(listView.rowView(for: id))
        let lightBubble = try #require(
            descendant(in: lightRow, identifier: "Transcript.UserBubble")
        )
        lightBubble.updateLayer()
        let lightLayerColor = try #require(
            lightBubble.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        )
        let light = try #require(lightLayerColor.usingColorSpace(.deviceRGB))
        let lightFrame = listView.rectForRow(with: id)

        listView.appearance = NSAppearance(named: .darkAqua)
        update(
            coordinator,
            listView,
            entries: [entry],
            colorScheme: .dark
        )
        listView.layoutSubtreeIfNeeded()
        let darkRow = try #require(listView.rowView(for: id))
        let darkBubble = try #require(
            descendant(in: darkRow, identifier: "Transcript.UserBubble")
        )
        darkBubble.updateLayer()
        let darkLayerColor = try #require(
            darkBubble.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        )
        let dark = try #require(darkLayerColor.usingColorSpace(.deviceRGB))

        #expect(abs(light.alphaComponent - 0.10) < 0.002)
        #expect(abs(dark.alphaComponent - 0.10) < 0.002)
        #expect(listView.rectForRow(with: id).size == lightFrame.size)
    }

    @Test
    func userChipKeepsTheOldHalfQuaternaryFillInLightAndDarkAppearances() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let coordinator = TranscriptListView.Coordinator()
            let listView = coordinator.makeListView()
            listView.appearance = NSAppearance(named: appearanceName)
            listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
            let id = UUID()
            let chip = ContextChipReference(kind: .file, label: "notes.md")
            let entry = TranscriptEntry(
                id: id,
                content: .user(
                    ChatMessage(
                        id: id,
                        role: .user,
                        text: "Review this",
                        contextChips: [chip]
                    ),
                    canEdit: false
                )
            )

            update(coordinator, listView, entries: [entry])
            listView.layoutSubtreeIfNeeded()

            let row = try #require(listView.rowView(for: id))
            let chipView = try #require(
                descendant(in: row, identifier: "Transcript.UserChip")
            )
            let chipContent = try #require(
                descendant(in: chipView, identifier: "Transcript.UserChipContent")
            )
            chipView.updateLayer()
            let color = try #require(
                chipView.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
            )
            #expect(abs(color.alphaComponent - 0.049) < 0.002)
            #expect(abs(chipView.bounds.width - chipContent.bounds.width - 12) <= 1)
            #expect(abs(chipView.bounds.height - chipContent.bounds.height - 6) <= 1)
        }
    }

    @Test
    func terminalSuggestionUsesTheSameSurfaceAsThePlanCard() throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        listView.appearance = NSAppearance(named: .aqua)
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 800)
        let id = UUID()
        let suggestion = SuggestedCommand(
            id: id,
            command: "pwd",
            explanation: "Show the current directory."
        )
        let entry = TranscriptEntry(
            id: id,
            content: .command(suggestion)
        )

        update(
            coordinator,
            listView,
            entries: [entry],
            showsTerminalActions: true,
            actions: .init(canDeliverCommand: { true })
        )
        listView.layoutSubtreeIfNeeded()

        let row = try #require(listView.rowView(for: id))
        let card = try #require(descendant(in: row, identifier: "Transcript.CommandCard"))
        let content = try #require(
            descendant(in: card, identifier: "Transcript.CommandCardContent") as? NSStackView
        )
        let commandBackground = try #require(
            descendant(in: card, identifier: "Transcript.CommandCardCommandBackground")
        )
        let command = try #require(
            descendant(in: card, identifier: "Transcript.CommandCardCommand") as? NSTextField
        )
        let explanation = try #require(
            descendant(in: card, identifier: "Transcript.CommandCardExplanation") as? NSTextField
        )
        let insert = try #require(
            descendant(in: card, identifier: "Transcript.CommandCardInsert") as? NSButton
        )
        let run = try #require(
            descendant(in: card, identifier: "Transcript.CommandCardRun") as? NSButton
        )

        card.displayIfNeeded()
        commandBackground.displayIfNeeded()
        let cardColor = try #require(card.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        let commandColor = try #require(
            commandBackground.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        )
        // A detached layer can resolve a named AppKit color as clear while the
        // test list has no window. The mounted app resolves it through the
        // owning appearance; this test owns the card hierarchy, not AppKit's
        // detached dynamic-color behavior.
        #expect(cardColor.alphaComponent == 0 || cardColor.alphaComponent == 1)
        #expect(card.layer?.cornerRadius == Metrics.Radius.large)
        #expect(card.layer?.borderWidth == 1)
        #expect(commandColor.alphaComponent == 0)
        #expect(content.spacing == Metrics.Space.m)
        #expect(command.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(command.font?.pointSize == NSFont.systemFontSize - 1)
        #expect(explanation.font?.pointSize == NSFont.smallSystemFontSize)
        #expect(insert.isBordered)
        #expect(run.isBordered)
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
            #expect(shortScroll.bounds.height >= 44)

            presentation.setMessageEditText(
                (1...12).map { "Expanded line \($0)" }.joined(separator: "\n"),
                for: id
            )
            coordinator.refreshDisplayedRow(id, in: listView)
            listView.layoutSubtreeIfNeeded()

            let tallScroll = try #require(
                descendant(in: row, identifier: "Transcript.UserEditorScroll")
            )
            #expect(tallScroll.bounds.height > shortScroll.bounds.height)
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
                target: .local, safety: .locallyReadOnly
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

        presentation.toggleDisclosure(plan.id)
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
        colorScheme: ColorScheme = .light
    ) {
        coordinator.update(
            listView: listView,
            entries: entries,
            latestUserMessageID: nil,
            configuration: .init(
                isCompact: isCompact,
                showsTerminalActions: showsTerminalActions,
                isConversationStreaming: false,
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

    private func pointerEvent() -> NSEvent? {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
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
