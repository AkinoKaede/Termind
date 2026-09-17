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
                state.toggleDisclosure(.toolDetail(card.id))
                try await Task.sleep(for: .milliseconds(20))
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                let expanded = controller.sizeThatFits(in: size)
                #expect(expanded.height >= compact.height)
                if card.descriptor.name != "skill_install" { #expect(expanded.height > compact.height) }
                #expect(state.isExpanded(.toolDetail(card.id)))
            }
        }
    }

    @Test func largerTextScalesThePreviewRatherThanHidingItsControls() {
        let detail = AgentToolDetail(items: [
            .text(.init(text: String(repeating: "Readable memory\n", count: 100), style: .plain))
        ])
        let controller = UIHostingController(
            rootView:
                AssistantCompactToolDetails(detail: detail, isError: false, expanded: .constant(false), copy: { _ in })
                .environment(\.dynamicTypeSize, .accessibility2))
        let size = controller.sizeThatFits(in: CGSize(width: 390, height: 30_000))
        #expect(size.height > 180)
        #expect(size.height < 800)
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
