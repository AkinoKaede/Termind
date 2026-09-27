import AgentKit
import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite
@MainActor
struct MobileAssistantAgentOriginTests {
    @Test
    func markerUsesLiveTitleThenRetainsSnapshotAndDisablesNavigationAfterDeletion() {
        let source = ConversationModel()
        source.customTitle = "Live source"
        let library = AssistantConversationStore(conversations: [source])
        let origin = AgentMessageOrigin(
            sourceConversationID: source.id, sourceRunID: UUID(),
            sourceToolCallID: "send", sourceTitle: "Snapshot source")

        for language in ["en", "zh-Hans", "zh-Hant"] {
            let locale = Locale(identifier: language)
            let live = MobileAssistantAgentOriginPresentation(
                origin: origin, source: library.conversation(id: source.id),
                locale: locale)
            #expect(live.canNavigate)
            #expect(
                live.label
                    == AppLocalization.resolve(
                        AppStrings.Assistant.agentFrom("Live source"), locale: locale))
        }

        _ = library.remove(source.id)
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let locale = Locale(identifier: language)
            let deleted = MobileAssistantAgentOriginPresentation(
                origin: origin, source: library.conversation(id: source.id),
                locale: locale)
            #expect(!deleted.canNavigate)
            #expect(
                deleted.label
                    == AppLocalization.resolve(
                        AppStrings.Assistant.agentFrom("Snapshot source"),
                        locale: locale))
        }
    }

    @Test
    func renderedMarkerUsesASingleSparklesControlAcrossLocalesAndAvailability() {
        #expect(MobileAssistantAgentOriginButton.systemImage == "sparkles")
        for language in ["en", "zh-Hans", "zh-Hant"] {
            for canNavigate in [true, false] {
                let source = canNavigate ? ConversationModel() : nil
                source?.customTitle = "Source"
                let sourceID = source?.id ?? UUID()
                let presentation = MobileAssistantAgentOriginPresentation(
                    origin: AgentMessageOrigin(
                        sourceConversationID: sourceID,
                        sourceRunID: UUID(),
                        sourceToolCallID: "send",
                        sourceTitle: "Source"),
                    source: source,
                    locale: Locale(identifier: language))
                let controller = UIHostingController(
                    rootView: MobileAssistantAgentOriginButton(
                        presentation: presentation,
                        navigate: {}
                    )
                    .fixedSize()
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.dynamicTypeSize, .accessibility3))
                let size = controller.sizeThatFits(
                    in: CGSize(width: 200, height: 200))

                #expect(abs(size.width - 44) < 0.5)
                #expect(abs(size.height - 44) < 0.5)
            }
        }
    }
}
