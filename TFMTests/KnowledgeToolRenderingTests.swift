import AgentKit
import AppKit
import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct KnowledgeToolRenderingTests {
    @Test(arguments: [380.0, 720.0])
    func knowledgeRowsStayCompactAndExpandWithoutLosingReaderState(_ width: Double) throws {
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            for card in AssistantTranscriptPreview.knowledgeCards(language: language) {
                let state = TranscriptPresentationState()
                state.disclosures.followDefault(true, for: .tool(card.id))
                let row = TranscriptNativeRow.make(for: .tool)
                func configure() {
                    row.configure(
                        entry: .init(id: card.id, content: .tool(card)), proposedWidth: width,
                        configuration: .init(
                            isCompact: true, showsTerminalActions: false, isConversationStreaming: false,
                            locale: language.locale, reduceMotion: true, colorScheme: .light),
                        actions: .init(), presentation: state, markdownCache: TranscriptMarkdownCache(limit: 4),
                        measurement: false, invalidate: { _, _ in })
                }
                configure()
                let compact = row.measuredHeight(for: width)
                #expect(compact > 20)
                if width == 720, ProcessInfo.processInfo.environment["TERMIND_KNOWLEDGE_SCREENSHOTS"] == "1" {
                    try snapshot(
                        row, width: width, height: compact, name: "mac-\(language.rawValue)-\(card.descriptor.name)")
                }
                let presenter = try #require(
                    AgentToolCatalog.builtInPresenters.first { $0.id == card.descriptor.presentation?.presenterID })
                let detail = try #require(
                    TermindToolPresentationProfiles.renderer.detail(
                        for: card, presenter: presenter, locale: language.locale))
                guard AgentToolDetailPreview(detail).isShortened else {
                    #expect(!state.disclosures.isExpanded(.toolDetail(card.id)))
                    continue
                }
                state.disclosures.toggleDisclosure(.toolDetail(card.id))
                configure()
                let expanded = row.measuredHeight(for: width)
                #expect(expanded > compact, "\(language.rawValue): \(card.descriptor.name)")
                configure()
                #expect(abs(row.measuredHeight(for: width) - expanded) < 0.5)
                #expect(state.disclosures.isExpanded(.toolDetail(card.id)))
                state.disclosures.toggleDisclosure(.toolDetail(card.id))
                configure()
                #expect(abs(row.measuredHeight(for: width) - compact) < 0.5)
                #expect(!state.disclosures.isExpanded(.toolDetail(card.id)))
            }
        }
    }

    private func snapshot(_ row: NSView, width: Double, height: Double, name: String) throws {
        let canvas = NSView(frame: CGRect(x: 0, y: 0, width: width + 32, height: ceil(height) + 32))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        row.translatesAutoresizingMaskIntoConstraints = true
        row.frame = CGRect(x: 16, y: 16, width: width, height: ceil(height))
        canvas.addSubview(row)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = canvas
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        canvas.layoutSubtreeIfNeeded()
        let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory.appending(path: "knowledge-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name + ".png")
        try data.write(to: url)
        row.removeFromSuperview()
        print("Knowledge snapshot: \(url.path)")
    }
}
