import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct RegistrationAndLayoutTests {
    @Test
    func slashRegistryFiltersExplicitPlatforms() {
        let conversation = ConversationModel(messages: [ChatMessage(role: .user, text: "Inspect")])
        let configuration = AIConfigurationModel()
        let skills = SkillLibraryModel()
        let registry = ChatSlashCommandRegistry.standard()
        let desktop = context(
            platform: .desktop,
            conversation: conversation,
            configuration: configuration,
            skills: skills,
            archive: {},
            newConversation: {}
        )
        let mobile = context(
            platform: .mobile,
            conversation: conversation,
            configuration: configuration,
            skills: skills,
            archive: {},
            newConversation: {}
        )

        #expect(Set(registry.commands(in: desktop).map(\.id)) == ["archive", "compact", "new", "plan", "skill"])
        #expect(Set(registry.commands(in: mobile).map(\.id)) == ["compact", "plan", "skill"])
        #expect(registry.commands(in: mobile).allSatisfy { $0.platforms.contains(.mobile) })
    }

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
    func librarySectionLayoutsFlattenExpandedTreesOnce() {
        let library = HostLibraryModel()
        let parent = HostGroup(name: "Production")
        let child = HostGroup(name: "Edge", parentID: parent.id)
        let host = Host(name: "Web", host: "web.invalid", groupID: child.id)
        library.upsert(parent)
        library.upsert(child)
        library.upsert(host)

        let sections = HostLibrarySectionLayout.sections(library: library)
        #expect(sections.map(\.title).prefix(2) == ["Production", "Production / Edge"])
        #expect(sections.first { $0.id == .group(child.id) }?.hosts.map(\.id) == [host.id])

        let snippets = SnippetLibraryModel(library: library)
        let package = SnippetPackage(name: "Deploy")
        snippets.upsert(package)
        snippets.upsert(Snippet(title: "Restart", body: "systemctl restart app", packageID: package.id))
        #expect(SnippetLibrarySectionLayout.sections(library: snippets).first?.title == "Deploy")
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

    private func context(
        platform: ChatSlashCommand.Platform,
        conversation: ConversationModel,
        configuration: AIConfigurationModel,
        skills: SkillLibraryModel,
        archive: (() -> Void)? = nil,
        newConversation: (() -> Void)? = nil
    ) -> ChatSlashCommandContext {
        ChatSlashCommandContext(
            platform: platform,
            conversation: conversation,
            configuration: configuration,
            skills: skills,
            archive: archive,
            newConversation: newConversation,
            compact: { _ in },
            send: {}
        )
    }
}
