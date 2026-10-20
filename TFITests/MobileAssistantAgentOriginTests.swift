// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindPresentation
import Testing

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

}
