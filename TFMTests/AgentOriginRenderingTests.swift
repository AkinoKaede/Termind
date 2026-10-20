// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import AppKit
import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing

@testable import Termind

@Suite
@MainActor
struct AgentOriginRenderingTests {
    @Test
    func markerRetainsSnapshotAndCopyButDisablesNavigationAfterSourceDeletion() throws {
        let sourceID = UUID()
        let messageID = UUID()
        let message = ChatMessage(
            id: messageID, role: .user, text: "Delegated text",
            origin: AgentMessageOrigin(
                sourceConversationID: sourceID, sourceRunID: UUID(),
                sourceToolCallID: "send", sourceTitle: "Snapshot source"))
        let entry = TranscriptEntry(
            id: messageID, content: .user(message, canEdit: true))
        let row = TranscriptNativeRow.make(for: .user)
        var navigated: UUID?
        let actions = TranscriptListActions(
            navigateChat: { navigated = $0 })

        configure(
            row, entry: entry, chatDestinations: [sourceID: "Live source"],
            actions: actions)
        var buttons = descendantButtons(in: row)
        let liveMarker = try #require(
            buttons.first {
                $0.identifier?.rawValue == "Transcript.AgentOrigin"
            })
        #expect(liveMarker.isEnabled)
        #expect(liveMarker.title.isEmpty)
        #expect(liveMarker.imagePosition == .imageOnly)
        #expect(
            liveMarker.toolTip
                == AppLocalization.resolve(
                    AppStrings.Assistant.agentFrom("Live source"),
                    locale: Locale(identifier: "en")))
        #expect(liveMarker.image != nil)
        expectVisibleAncestors(from: liveMarker, through: row)
        #expect(buttons.contains { $0.toolTip == String(localized: AppStrings.Common.copy) })
        #expect(!buttons.contains { $0.toolTip == String(localized: AppStrings.Common.edit) })
        liveMarker.performClick(nil)
        #expect(navigated == sourceID)

        configure(row, entry: entry, chatDestinations: [:], actions: actions)
        buttons = descendantButtons(in: row)
        let deletedMarker = try #require(
            buttons.first {
                $0.identifier?.rawValue == "Transcript.AgentOrigin"
            })
        #expect(!deletedMarker.isEnabled)
        #expect(deletedMarker.title.isEmpty)
        #expect(deletedMarker.imagePosition == .imageOnly)
        #expect(
            deletedMarker.toolTip
                == AppLocalization.resolve(
                    AppStrings.Assistant.agentFrom("Snapshot source"),
                    locale: Locale(identifier: "en")))
        expectVisibleAncestors(from: deletedMarker, through: row)
        #expect(buttons.contains { $0.toolTip == String(localized: AppStrings.Common.copy) })
        #expect(!buttons.contains { $0.toolTip == String(localized: AppStrings.Common.edit) })
    }

    private func configure(
        _ row: TranscriptNativeRow, entry: TranscriptEntry,
        chatDestinations: [UUID: String], actions: TranscriptListActions
    ) {
        row.configure(
            entry: entry, proposedWidth: 420,
            configuration: .init(
                isCompact: false, showsTerminalActions: false,
                isConversationStreaming: false,
                chatDestinations: chatDestinations,
                locale: Locale(identifier: "en"), reduceMotion: true,
                colorScheme: .light),
            actions: actions, presentation: TranscriptPresentationState(),
            markdownCache: TranscriptMarkdownCache(limit: 4),
            measurement: false, invalidate: { _, _ in })
        row.layoutSubtreeIfNeeded()
    }

    private func descendantButtons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            (child as? NSButton).map { [$0] } ?? descendantButtons(in: child)
        }
    }

    private func expectVisibleAncestors(from view: NSView, through root: NSView) {
        var current: NSView? = view
        while let node = current {
            #expect(node.alphaValue > 0)
            if node === root { return }
            current = node.superview
        }
        Issue.record("Marker is not attached to its transcript row")
    }
}
