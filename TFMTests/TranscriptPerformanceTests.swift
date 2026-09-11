import Darwin
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
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
            // Twenty actual presentation frames, each applied immediately.
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
