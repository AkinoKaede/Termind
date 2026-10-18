import AgentKit
import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileKnowledgeToolRenderingTests {
    @Test func knowledgeRowsStayCompactAtPhoneWidthAndExpandOnDemand() async throws {
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            for card in AssistantTranscriptPreview.knowledgeCards(language: language) {
                let state = AssistantTranscriptPresentationState()
                state.followDefault(true, for: .tool(card.id))
                let controller = UIHostingController(
                    rootView:
                        MobileAssistantToolRow(card: card, presentation: state, hostName: { _ in "Unused" })
                        .environment(\.locale, language.locale)
                        .environment(\.mobileListReduceMotion, true)
                        .padding(16)
                        .background(Color(uiColor: .systemBackground)))
                let size = CGSize(width: 390, height: 30_000)
                let compact = controller.sizeThatFits(in: size)
                #expect(compact.height <= 360, "\(card.descriptor.name): \(compact.height)")
                #expect(compact.height > 40)
                controller.view.frame = CGRect(origin: .zero, size: compact)
                controller.view.layoutIfNeeded()
                if ProcessInfo.processInfo.environment["TERMIND_KNOWLEDGE_SCREENSHOTS"] == "1" {
                    try snapshot(controller.view, name: "ios-\(language.rawValue)-\(card.descriptor.name)")
                }
                let detail = try detail(for: card, language: language)
                guard AgentToolDetailPreview(detail).isShortened else {
                    #expect(!state.isExpanded(.toolDetail(card.id)))
                    continue
                }
                state.toggleDisclosure(.toolDetail(card.id))
                try await Task.sleep(for: .milliseconds(20))
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                let expanded = controller.sizeThatFits(in: size)
                #expect(expanded.height > compact.height, "\(language.rawValue): \(card.descriptor.name)")
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                #expect(abs(controller.sizeThatFits(in: size).height - expanded.height) < 0.5)
                #expect(state.isExpanded(.toolDetail(card.id)))
                state.toggleDisclosure(.toolDetail(card.id))
                try await Task.sleep(for: .milliseconds(20))
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                #expect(abs(controller.sizeThatFits(in: size).height - compact.height) < 0.5)
                #expect(!state.isExpanded(.toolDetail(card.id)))
            }
        }
    }

    @Test func shortKnowledgeDetailsKeepTheirNaturalHeight() throws {
        for language in [AppLanguage.english, .simplifiedChinese, .traditionalChinese] {
            var shortCards = 0
            for card in AssistantTranscriptPreview.knowledgeCards(language: language) {
                let detail = try detail(for: card, language: language)
                guard !AgentToolDetailPreview(detail).isShortened else { continue }
                shortCards += 1
                let natural = UIHostingController(
                    rootView:
                        AssistantToolDetails(items: detail.items)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.locale, language.locale))
                let compact = UIHostingController(
                    rootView:
                        AssistantCompactToolDetails(
                            detail: detail, isError: false, expanded: .constant(false)
                        )
                        .environment(\.locale, language.locale))
                let proposal = CGSize(width: 334, height: 30_000)
                let naturalHeight = natural.sizeThatFits(in: proposal).height
                #expect(naturalHeight > 0 && naturalHeight < 180)
                #expect(
                    abs(compact.sizeThatFits(in: proposal).height - naturalHeight) < 0.5,
                    "\(language.rawValue): \(card.descriptor.name)")
            }
            #expect(shortCards > 0)
        }
    }

    @Test func largerTextScalesThePreviewRatherThanHidingItsControls() {
        let detail = AgentToolDetail(items: [
            .text(.init(text: String(repeating: "Readable memory\n", count: 100), style: .plain))
        ])
        let controller = UIHostingController(
            rootView:
                AssistantCompactToolDetails(detail: detail, isError: false, expanded: .constant(false))
                .environment(\.dynamicTypeSize, .accessibility2))
        let size = controller.sizeThatFits(in: CGSize(width: 390, height: 30_000))
        #expect(size.height > 180)
        #expect(size.height < 800)
    }

    @Test func expandedDetailsShowTheEntireOutputWithoutLegacyTruncation() {
        let detail = AgentToolDetail(items: [
            .text(.init(text: String(repeating: "Full output line\n", count: 240), style: .monospaced))
        ])
        let full = UIHostingController(
            rootView: AssistantToolDetails(items: detail.items))
        let expanded = UIHostingController(
            rootView: AssistantCompactToolDetails(
                detail: detail, isError: false, expanded: .constant(true)))
        let proposal = CGSize(width: 390, height: 30_000)
        let fullHeight = full.sizeThatFits(in: proposal).height
        let expandedHeight = expanded.sizeThatFits(in: proposal).height
        #expect(expandedHeight > fullHeight)
        #expect(expandedHeight < fullHeight + 100)
    }

    private func detail(for card: AgentToolCard, language: AppLanguage) throws -> AgentToolDetail {
        let presenter = try #require(
            AgentToolCatalog.builtInPresenters.first { $0.id == card.descriptor.presentation?.presenterID })
        return try #require(
            TermindToolPresentationProfiles.renderer.detail(for: card, presenter: presenter, locale: language.locale))
    }

    private func snapshot(_ view: UIView, name: String) throws {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { context in
            view.layer.render(in: context.cgContext)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "knowledge-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name + ".png")
        try #require(image.pngData()).write(to: url)
        print("Knowledge snapshot: \(url.path)")
    }
}
