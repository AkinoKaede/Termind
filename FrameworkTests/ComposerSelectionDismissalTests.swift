// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindApplication
import Testing

@Suite @MainActor
struct ComposerSelectionDismissalTests {
    @Test
    func backspaceDismissesSkillBeforePlanWithoutRemovingContext() {
        let conversation = ConversationModel()
        conversation.isPlanning = true
        conversation.composer.armedSkillName = "disk-triage"
        let attachment = ContextChip(kind: .selection, label: "Selection", content: "df -h")
        conversation.attach(attachment)
        let pending = PendingContextAttachment(label: "upload.txt")
        conversation.composer.pendingAttachments = [pending]

        #expect(conversation.dismissLastComposerSelectionIfDraftEmpty())
        #expect(conversation.composer.armedSkillName == nil)
        #expect(conversation.isPlanning)
        #expect(conversation.dismissLastComposerSelectionIfDraftEmpty())
        #expect(!conversation.isPlanning)
        #expect(!conversation.dismissLastComposerSelectionIfDraftEmpty())
        #expect(conversation.composer.attachments == [attachment])
        #expect(conversation.composer.pendingAttachments == [pending])
        #expect(conversation.composer.draft.isEmpty)
        #expect(conversation.transcript.isEmpty)
    }

    @Test(arguments: [true, false])
    func aSingleSelectionIsDismissed(planning: Bool) {
        let conversation = ConversationModel()
        conversation.isPlanning = planning
        conversation.composer.armedSkillName = planning ? nil : "disk-triage"

        #expect(conversation.dismissLastComposerSelectionIfDraftEmpty())
        #expect(!conversation.isPlanning)
        #expect(conversation.composer.armedSkillName == nil)
        #expect(!conversation.dismissLastComposerSelectionIfDraftEmpty())
    }

    @Test(arguments: ["text", " ", "\n", "\t", " \n"])
    func anyDraftContentKeepsBothSelections(draft: String) {
        let conversation = ConversationModel()
        conversation.composer.draft = draft
        conversation.isPlanning = true
        conversation.composer.armedSkillName = "disk-triage"

        #expect(!conversation.dismissLastComposerSelectionIfDraftEmpty())
        #expect(conversation.composer.draft == draft)
        #expect(conversation.isPlanning)
        #expect(conversation.composer.armedSkillName == "disk-triage")
    }

    @Test
    func anEmptyComposerWithoutSelectionsDoesNotConsumeBackspace() {
        #expect(!ConversationModel().dismissLastComposerSelectionIfDraftEmpty())
    }
}
