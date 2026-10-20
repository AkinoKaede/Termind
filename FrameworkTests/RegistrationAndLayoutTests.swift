// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct RegistrationAndLayoutTests {
    @Test
    func planRegistrationOwnsExecutionAlongsideItsDescriptor() {
        let conversation = ConversationModel()
        conversation.composer.draft = "/plan inspect disk"
        var sends = 0
        let context = ChatSlashCommandContext(
            platform: .mobile,
            conversation: conversation,
            configuration: AIConfigurationModel(),
            skills: SkillLibraryModel(),
            compact: { _ in },
            send: { sends += 1 }
        )

        #expect(ChatSlashCommandRegistry.standard().perform(draft: conversation.composer.draft, in: context))
        #expect(conversation.isPlanning)
        #expect(conversation.composer.draft == "inspect disk")
        #expect(sends == 1)
    }

    @Test
    func vaultRemoteChangePlanDetectsRouteChangesAndRemovals() {
        let changed = Host(name: "Changed", host: "old.invalid")
        let removed = Host(name: "Removed", host: "removed.invalid")
        var updated = changed
        updated.host = "new.invalid"
        let forwardingID = UUID()
        let keys: Set<VaultRecordKey> = [
            VaultRecordKey(kind: .host, id: changed.id),
            VaultRecordKey(kind: .host, id: removed.id),
            VaultRecordKey(kind: .portForwarding, id: forwardingID),
        ]

        let plan = VaultRemoteChangePlan.make(
            currentHosts: [changed, removed],
            snapshot: VaultSnapshot(hosts: [updated]),
            changedKeys: keys
        )

        #expect(plan.hosts.first { $0.id == changed.id }?.routeChanged == true)
        #expect(plan.hosts.first { $0.id == changed.id }?.isRemoved == false)
        #expect(plan.hosts.first { $0.id == removed.id }?.isRemoved == true)
        #expect(plan.forwardingRuleIDs == [forwardingID])
    }

}
