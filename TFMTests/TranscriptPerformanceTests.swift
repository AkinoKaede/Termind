import Darwin
import Foundation
import TermindApplication
import TermindPresentation
import Testing

@testable import Termind

@MainActor
@Suite(.serialized)
struct TranscriptPerformanceTests {
    @Test
    func correctRendererScrollAndStreamingBenchmark() {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 640)
        var items = makeItems(count: 300)
        let footprintBefore = physicalFootprint()

        let initial = elapsed {
            update(coordinator, listView, items: items)
            listView.layoutSubtreeIfNeeded()
        }

        let maximum = max(0, listView.maximumContentOffset.y)
        let offsets = stride(from: CGFloat.zero, through: maximum, by: 180).map { $0 }
        let passes =
            Int(
                ProcessInfo.processInfo.environment["TRANSCRIPT_BENCHMARK_PASSES"] ?? "3"
            ) ?? 3
        let scroll = elapsed {
            for _ in 0..<passes {
                for offset in offsets {
                    listView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    listView.layoutSubtreeIfNeeded()
                }
                for offset in offsets.reversed() {
                    listView.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                    listView.layoutSubtreeIfNeeded()
                }
            }
        }

        let lastID = items[items.count - 1].id
        let stream = elapsed {
            // Twenty synchronous presentation updates, not twenty displayed frames.
            for revision in 0..<20 {
                let message = ChatMessage(
                    id: lastID,
                    role: .assistant,
                    text: Self.markdown(index: 299)
                        + String(repeating: " token", count: revision + 1),
                    isStreaming: true
                )
                items[items.count - 1] = TranscriptEntry(
                    id: lastID,
                    content: .assistant(message, canFork: false),
                    hasLeadingSpacing: true
                )
                update(coordinator, listView, items: items)
                listView.layoutSubtreeIfNeeded()
            }
        }

        let footprintAfter = physicalFootprint()
        let footprintDelta =
            footprintAfter >= footprintBefore ? footprintAfter - footprintBefore : 0
        print(
            String(
                format:
                    "TRANSCRIPT_BENCHMARK renderer=correct initial_ms=%.1f scroll_ms=%.1f stream_ms=%.1f footprint_delta_mb=%.1f mounted_rows=%d",
                initial * 1_000,
                scroll * 1_000,
                stream * 1_000,
                Double(footprintDelta) / 1_048_576,
                listView.visibleRowViews.count
            ))

        #expect(listView.visibleRowViews.count < 40)
        #expect(scroll < 30)
        #expect(stream < 5)
    }

    @Test(arguments: [false, true])
    func modelDrivenStreamingReplayReportsUpdateCosts(readingHistory: Bool) async throws {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        listView.frame = CGRect(x: 0, y: 0, width: 420, height: 640)
        let presentation = TranscriptPresentationState()
        let messages = (0..<300).map { ChatMessage(role: .assistant, text: Self.markdown(index: $0)) }
        let conversation = ConversationModel(messages: messages)
        let lastID = try #require(messages.last?.id)

        func applyConversation() -> (projection: TimeInterval, rendering: TimeInterval) {
            var entries: [TranscriptEntry] = []
            let projection = elapsed {
                let availability = conversation.messageActionAvailability
                entries = TranscriptEntry.items(
                    timeline: conversation.timeline,
                    isInterrupted: conversation.runState == .interrupted,
                    canEdit: availability.editable.contains,
                    canFork: availability.forkable.contains
                )
            }
            let rendering = elapsed {
                coordinator.update(
                    listView: listView, entries: entries, latestUserMessageID: nil,
                    configuration: .init(
                        isCompact: true, showsTerminalActions: false,
                        isConversationStreaming: conversation.isStreaming,
                        locale: Locale(identifier: "en"), reduceMotion: false, colorScheme: .light
                    ),
                    actions: .init(), presentation: presentation
                )
                listView.layoutSubtreeIfNeeded()
            }
            return (projection, rendering)
        }

        _ = applyConversation()
        if readingHistory {
            listView.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
            listView.layoutSubtreeIfNeeded()
        }
        let anchorIndex = try #require(listView.indicesForVisibleRows.first)
        let anchorID = listView.content[anchorIndex].id
        let anchor = try #require(listView.rowView(for: anchorID))
        let anchorOffset = listView.rectForRow(with: anchorID).minY - listView.contentOffset.y
        var projectionSamples: [TimeInterval] = []
        var renderSamples: [TimeInterval] = []
        var eventSamples: [TimeInterval] = []
        var maximumAnchorDrift: CGFloat = 0
        var anchorReplacements = 0
        var previousAnchor = anchor

        conversation.handle(.runState(.running))
        for revision in 0..<20 {
            eventSamples.append(
                elapsed {
                    conversation.handle(.messageDelta(messageID: lastID, text: "\n\nReplay paragraph \(revision)."))
                })
            let sample = applyConversation()
            projectionSamples.append(sample.projection)
            renderSamples.append(sample.rendering)
            // Give deferred layout work a turn; this remains an offscreen replay,
            // not a measurement of display refresh or animation hitch rate.
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            listView.layoutSubtreeIfNeeded()
            if readingHistory {
                let current = try #require(listView.rowView(for: anchorID))
                if current !== previousAnchor { anchorReplacements += 1 }
                previousAnchor = current
                maximumAnchorDrift = max(
                    maximumAnchorDrift,
                    abs(listView.rectForRow(with: anchorID).minY - listView.contentOffset.y - anchorOffset)
                )
            }
        }
        conversation.handle(.runState(.completed))
        _ = applyConversation()
        if readingHistory {
            let current = try #require(listView.rowView(for: anchorID))
            if current !== previousAnchor { anchorReplacements += 1 }
            maximumAnchorDrift = max(
                maximumAnchorDrift,
                abs(listView.rectForRow(with: anchorID).minY - listView.contentOffset.y - anchorOffset)
            )
            #expect(current === anchor)
            #expect(maximumAnchorDrift <= 1)
        }
        let last = try #require(listView.content.first(where: { $0.id == lastID }))
        guard case .assistant(let message, _) = last.content else {
            Issue.record("Expected the streamed assistant message")
            return
        }
        #expect(message.text.hasSuffix("Replay paragraph 19."))
        #expect(!message.isStreaming)
        print(
            String(
                format:
                    "TRANSCRIPT_MODEL_REPLAY history=%@ event_p95_ms=%.2f projection_p95_ms=%.2f render_p50_ms=%.2f render_p95_ms=%.2f render_max_ms=%.2f anchor_drift=%.2f anchor_replacements=%d",
                readingHistory.description,
                percentile(eventSamples, fraction: 0.95) * 1_000,
                percentile(projectionSamples, fraction: 0.95) * 1_000,
                percentile(renderSamples, fraction: 0.5) * 1_000,
                percentile(renderSamples, fraction: 0.95) * 1_000,
                (renderSamples.max() ?? 0) * 1_000,
                Double(maximumAnchorDrift), anchorReplacements
            ))
    }

    private func percentile(_ samples: [TimeInterval], fraction: Double) -> TimeInterval {
        let sorted = samples.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))]
    }

    private func makeItems(count: Int) -> [TranscriptEntry] {
        (0..<count).map { index in
            let id = UUID()
            return TranscriptEntry(
                id: id,
                content: .assistant(
                    ChatMessage(
                        id: id,
                        role: .assistant,
                        text: Self.markdown(index: index)
                    ),
                    canFork: false
                ),
                hasLeadingSpacing: index > 0
            )
        }
    }

    private static func markdown(index: Int) -> String {
        """
        ## Result \(index)

        This is a representative assistant response with **emphasis**, a [safe link](https://example.com), and enough prose to wrap across several lines in the compact transcript.

        - first item
        - second item
        - third item

        ```swift
        let value = \(index)
        print(value)
        ```
        """
    }

    private func update(
        _ coordinator: TranscriptListView.Coordinator,
        _ listView: TranscriptListView.NativeListView,
        items: [TranscriptEntry]
    ) {
        coordinator.update(
            listView: listView,
            entries: items,
            latestUserMessageID: nil,
            configuration: .init(
                isCompact: true,
                showsTerminalActions: false,
                isConversationStreaming: false,
                locale: Locale(identifier: "en"),
                reduceMotion: true,
                colorScheme: .light
            ),
            actions: .init(),
            presentation: TranscriptPresentationState()
        )
    }

    private func elapsed(_ operation: () -> Void) -> TimeInterval {
        let start = ContinuousClock.now
        operation()
        let duration = start.duration(to: .now).components
        return TimeInterval(duration.seconds) + TimeInterval(duration.attoseconds) / 1e18
    }

    private func physicalFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
