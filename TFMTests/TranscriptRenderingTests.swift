import AppKit
import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct TranscriptRenderingTests {
    @Test func renderTranscriptWorkStates() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_ASSISTANT_SCREENSHOTS"] == "1" else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: "assistant-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for language in ["en", "zh-Hans"] {
            for phase in AssistantTranscriptPreview.Phase.allCases {
                for dark in [false, true] {
                    let group = AssistantTranscriptPreview.work(
                        language: language == "en" ? .english : .simplifiedChinese, phase: phase
                    )
                    let presentation = TranscriptPresentationState()
                    presentation.disclosures.followDefault(true, for: .work(group.id))
                    for item in group.items {
                        switch item {
                        case .tool(let card):
                            presentation.disclosures.followDefault(true, for: .tool(card.id))
                        case .tools(let batch):
                            presentation.disclosures.followDefault(true, for: .toolBatch(batch.id))
                            for card in batch.cards {
                                presentation.disclosures.followDefault(true, for: .tool(card.id))
                            }
                        case .reasoning, .message:
                            break
                        }
                    }
                    let row = TranscriptNativeRow.make(for: .work)
                    row.configure(
                        entry: .init(id: group.id, content: .work(group)), proposedWidth: 840,
                        configuration: .init(
                            isCompact: false, showsTerminalActions: false, isConversationStreaming: phase != .results,
                            locale: Locale(identifier: language), reduceMotion: false,
                            colorScheme: dark ? .dark : .light
                        ), actions: .init(), presentation: presentation,
                        markdownCache: TranscriptMarkdownCache(limit: 48),
                        measurement: false, invalidate: { _, _ in }
                    )
                    let height = ceil(row.measuredHeight(for: 840))
                    row.translatesAutoresizingMaskIntoConstraints = true
                    row.frame = CGRect(x: 0, y: 24, width: 840, height: height)
                    let canvas = NSView(frame: CGRect(x: 0, y: 0, width: 840, height: height + 48))
                    canvas.wantsLayer = true
                    canvas.addSubview(row)
                    let window = NSWindow(
                        contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = canvas
                    window.appearance?.performAsCurrentDrawingAppearance {
                        canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                    }
                    window.orderFront(nil)
                    defer {
                        window.orderOut(nil)
                        window.contentView = nil
                    }
                    row.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(400))
                    let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
                    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    let url = directory.appending(
                        path: "mac-\(language)-work-\(phase.rawValue)-\(dark ? "dark" : "light").png")
                    try data.write(to: url)
                    print("Assistant snapshot: \(url.path)")
                }
            }
        }
    }
}
