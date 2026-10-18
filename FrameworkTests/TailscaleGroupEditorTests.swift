import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct TailscaleGroupEditorTests {
    @Test func fieldsCanBeChangedRevertedAndChangedAgain() throws {
        let fixture = try EditorFixture(existing: true)
        let group = try #require(fixture.library.groups.first)
        let editor = fixture.editor(group)
        let hostname = editor.hostname
        let controlURL = editor.controlURL
        let exitNodeID = editor.exitNodeID
        #expect(!editor.isDirty)
        for _ in 0..<2 {
            editor.draft.name = "Changed"
            #expect(editor.isDirty)
            editor.draft.name = group.name
            #expect(!editor.isDirty)
            editor.hostname = "another-device"
            #expect(editor.isDirty)
            editor.hostname = hostname
            #expect(!editor.isDirty)
            editor.controlURL = "https://other.example.com"
            #expect(editor.isDirty)
            editor.controlURL = controlURL
            #expect(!editor.isDirty)
            editor.exitNodeID = "other-exit"
            #expect(editor.isDirty)
            editor.exitNodeID = exitNodeID
            #expect(!editor.isDirty)
            editor.setEnabled(false)
            #expect(editor.isDirty)
            editor.setEnabled(true)
            #expect(!editor.isDirty)
        }
    }

    @Test func hostnameDirtinessUsesTheEditorBaselineNotLiveStorage() async throws {
        let fixture = try EditorFixture()
        let group = try await fixture.connect()
        let editor = fixture.editor(group)
        let originalHostname = editor.hostname
        try await fixture.model.saveHostname("external-device", groupID: group.id)
        #expect(!editor.isDirty)
        editor.hostname = "external-device"
        #expect(editor.isDirty)
        editor.hostname = originalHostname
        #expect(!editor.isDirty)
        editor.hostname = "saved-device"
        _ = try await editor.save()
        #expect(!editor.isDirty)
        editor.hostname = originalHostname
        #expect(editor.isDirty)
        editor.hostname = "saved-device"
        #expect(!editor.isDirty)
        await fixture.model.shutdown()
    }

    @Test func failedLoginDoesNotKeepARevertedFormDirty() async throws {
        let fixture = try EditorFixture(existing: true)
        let group = try #require(fixture.library.groups.first)
        let editor = fixture.editor(group)
        let originalControlURL = editor.controlURL
        let originalHostname = editor.hostname
        editor.controlURL = "://"
        editor.login(authKey: nil)
        #expect(editor.isDirty)
        try await wait { fixture.model.error != nil && !editor.isLoggingIn }
        #expect(editor.operationID != nil && editor.pending == nil)
        editor.controlURL = originalControlURL
        #expect(!editor.isDirty)
        editor.login(authKey: nil)
        #expect(editor.isDirty)
        try await fixture.ready(editor)
        #expect(editor.isDirty)
        editor.hostname = originalHostname
        #expect(editor.isDirty)
        editor.cancel()
        #expect(!editor.isDirty)
        await fixture.model.shutdown()
    }

    @Test(arguments: ["", "My servers"])
    func loginWithoutSavingOnlyUpdatesTheEditor(name: String) async throws {
        let fixture = try EditorFixture()
        let editor = fixture.editor()
        editor.draft.name = name
        editor.setEnabled(true)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        #expect(editor.draft.name == (name.isEmpty ? "Test Tailnet" : name))
        #expect(editor.canSave)
        #expect(editor.isConnected)
        #expect(editor.isDirty)
        #expect(editor.candidates.count == 1)
        #expect(fixture.library.groups.isEmpty)
        #expect(fixture.library.hosts.isEmpty)
        #expect(try fixture.store.load().isEmpty)
        #expect(fixture.model.loginCompletedGroupID == nil)
        #expect(throws: TailscaleConfigurationError.self) { try fixture.model.connection(for: editor.draft.id) }
        // Further editing is reflected only when the user explicitly saves.
        editor.draft.name = "Edited after login"
        editor.hostname = "my-laptop"
        editor.exitNodeID = "exit"
        let saved = try await editor.save()
        #expect(saved.name == "Edited after login")
        #expect(saved.tailscale?.exitNodeID == "exit")
        #expect(fixture.node.hostname == "my-laptop")
        #expect(fixture.node.exitNode == "exit")
        #expect(fixture.library.hosts.count == 1)
        #expect(fixture.model.runningGroups.contains(saved.id))
        editor.cancel()
        #expect(!fixture.node.closed)
        await fixture.model.shutdown()
    }

    @Test func lateLoginDoesNotOverwriteANameTypedWhileAuthenticating() async throws {
        let fixture = try EditorFixture()
        fixture.node.holdStatus = true
        let editor = fixture.editor()
        editor.setEnabled(true)
        editor.login(authKey: nil)
        try await wait { fixture.node.statusContinuation != nil }
        editor.draft.name = "Typed while waiting"
        fixture.node.releaseStatus()
        try await fixture.ready(editor)
        #expect(editor.draft.name == "Typed while waiting")
        editor.cancel()
        await fixture.model.shutdown()
    }

    @Test func missingNetworkNameUsesDNSSuffixAndWhitespaceDoesNotBlockLogin() async throws {
        let fixture = try EditorFixture()
        fixture.node.networkName = "  "
        let editor = fixture.editor()
        editor.draft.name = " \n "
        editor.setEnabled(true)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        #expect(editor.draft.name == "test.ts.net")
        editor.cancel()
        await fixture.model.shutdown()
    }

    @Test(arguments: [false, true])
    func cancellingOrDisablingAnAuthenticatedDraftCleansOnlyItsCandidate(disable: Bool) async throws {
        let fixture = try EditorFixture()
        let editor = fixture.editor()
        editor.setEnabled(true)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        if disable { editor.setEnabled(false) } else { editor.cancel() }
        try await wait { fixture.node.closed }
        #expect(!editor.isConnected)
        #expect(fixture.node.logouts == 1)
        #expect(fixture.library.groups.isEmpty)
        #expect(try fixture.store.load().isEmpty)
        if disable {
            let saved = try await editor.save()
            #expect(saved.tailscale == nil)
        }
        await fixture.model.shutdown()
    }

    @Test(arguments: [false, true])
    func logoutOfAnUnsavedLoginTakesEffectImmediatelyInNewAndEdit(existing: Bool) async throws {
        let fixture = try EditorFixture(existing: existing)
        let savedGroups = fixture.library.groups
        let editor = fixture.editor(savedGroups.first)
        editor.setEnabled(true)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        #expect(editor.pending != nil && editor.isConnected)
        editor.logout()
        #expect(editor.pending == nil && !editor.isConnected && !editor.isLogoutPending)
        try await wait { fixture.node.closed }
        #expect(fixture.node.logouts == 1)
        #expect(fixture.library.groups == savedGroups)
        #expect(try fixture.store.load().isEmpty)
        await fixture.model.shutdown()
    }

    @Test func anOlderEditorCannotCancelAnotherEditorsLogin() async throws {
        let fixture = try EditorFixture()
        let first = fixture.editor()
        first.setEnabled(true)
        first.login(authKey: nil)
        try await fixture.ready(first)
        let second = fixture.editor()
        second.setEnabled(true)
        second.login(authKey: nil)
        let operation = second.operationID
        first.cancel()
        #expect(fixture.model.loginOperationID == operation)
        #expect(second.operationID == operation)
        second.cancel()
        await fixture.model.shutdown()
    }

    @Test(arguments: [false, true])
    func reloginPreservesOrReplacesNetworkPreferencesOnlyWhenSaved(switchNetwork: Bool) async throws {
        let fixture = try EditorFixture(existing: true, otherNetwork: switchNetwork)
        let group = try #require(fixture.library.groups.first)
        let editor = fixture.editor(group)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        #expect(fixture.library.group(group.id)?.tailscale == group.tailscale)
        #expect(fixture.model.runningGroups.isEmpty)
        let saved = try await editor.save()
        #expect(saved.id == group.id)
        let before = try #require(group.tailscale).hostID(groupID: group.id, stableNodeID: "exit")
        let after = try #require(saved.tailscale).hostID(groupID: saved.id, stableNodeID: "exit")
        #expect((before != after) == switchNetwork)
        #expect(saved.tailscale?.hostIdentityVersion == .groupScopedV2)
        #expect(saved.tailscale?.network == fixture.node.network)
        #expect(saved.tailscale?.username == (switchNetwork ? "" : "operator"))
        #expect(saved.tailscale?.exitNodeID == (switchNetwork ? nil : "exit"))
        #expect(saved.tailscale?.hostPreferences.isEmpty == switchNetwork)
        await fixture.model.shutdown()
    }

    @Test func disablingBindingPreservesManualHostsAndSubgroupsAndNotifiesCleanup() async throws {
        let fixture = try EditorFixture(existing: true)
        let group = try #require(fixture.library.groups.first)
        let child = HostGroup(name: "Child", parentID: group.id)
        fixture.library.upsert(child)
        var manual = Host(name: "Manual", host: "example.com")
        manual.groupID = group.id
        fixture.library.upsert(manual)
        fixture.library.replaceTailscalePeers(fixture.node.peers, groupID: group.id)
        let managed = try #require(fixture.library.hosts.first { $0.isTailscaleManaged })
        var removed: Set<UUID> = []
        fixture.library.didDeleteTailscaleGroups = { _, hosts in removed.formUnion(hosts) }
        let editor = fixture.editor(group)
        editor.setEnabled(false)
        #expect(fixture.library.group(group.id)?.tailscale != nil)
        let saved = try await editor.save()
        #expect(saved.tailscale == nil)
        #expect(fixture.library.host(manual.id) != nil)
        #expect(fixture.library.group(child.id)?.parentID == group.id)
        #expect(fixture.library.host(managed.id) == nil)
        #expect(removed == [managed.id])
        await fixture.model.shutdown()
    }

    @Test func localSaveFailureRetainsTheCandidateForRetry() async throws {
        let fixture = try EditorFixture()
        let editor = fixture.editor()
        editor.setEnabled(true)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        fixture.store.failSave = true
        await #expect(throws: (any Error).self) { try await editor.save() }
        #expect(fixture.library.group(editor.draft.id)?.tailscale != nil)
        #expect(editor.pending != nil)
        #expect(!fixture.node.closed)
        #expect(fixture.model.runningGroups.isEmpty)
        #expect(fixture.model.error != nil)
        fixture.store.failSave = false
        _ = try await editor.save()
        #expect(editor.pending == nil)
        #expect(fixture.model.runningGroups.contains(editor.draft.id))
        #expect(try fixture.store.load().count == 1)
        await fixture.model.shutdown()
    }

    @Test func syncedNetworkReplacementInvalidatesCachedPeersAndThePendingLogin() async throws {
        let fixture = try EditorFixture(existing: true)
        var group = try #require(fixture.library.groups.first)
        fixture.library.replaceTailscalePeers(fixture.node.peers, groupID: group.id)
        let editor = fixture.editor(group)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        group.tailscale = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: "https://other.example.com", dnsSuffix: "other.ts.net"))
        fixture.library.replacePersistedSnapshot(.init(groups: [group]))
        #expect(fixture.library.hosts.isEmpty)
        #expect(editor.pending == nil)
        await #expect(throws: (any Error).self) { try await editor.save() }
        #expect(fixture.library.group(group.id)?.tailscale == group.tailscale)
        try await wait { fixture.node.closed }
        await fixture.model.shutdown()
    }

    @Test func cancellationDuringSaveCannotActivateTheLateResult() async throws {
        let fixture = try EditorFixture()
        let editor = fixture.editor()
        editor.setEnabled(true)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        fixture.node.holdStatus = true
        let saving = Task { try await editor.save() }
        try await wait { fixture.node.statusContinuation != nil }
        editor.cancel()
        for _ in 0..<10 { await Task.yield() }
        #expect(!fixture.node.closed)
        fixture.node.releaseStatus()
        await #expect(throws: (any Error).self) { try await saving.value }
        try await wait { fixture.node.closed }
        #expect(fixture.library.groups.isEmpty)
        #expect(fixture.model.runningGroups.isEmpty)
        await fixture.model.shutdown()
    }

    @Test func vaultSaveFailureKeepsTheCandidateAndDoesNotCreateAGroup() async throws {
        let fixture = try EditorFixture()
        let editor = fixture.editor()
        editor.setEnabled(true)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        fixture.vault.failSave = true
        await #expect(throws: (any Error).self) { try await editor.save() }
        #expect(fixture.library.groups.isEmpty)
        #expect(try fixture.store.load().isEmpty)
        #expect(editor.pending != nil)
        #expect(!fixture.node.closed)
        fixture.vault.failSave = false
        _ = try await editor.save()
        #expect(fixture.library.groups.count == 1)
        #expect(fixture.model.runningGroups.contains(editor.draft.id))
        await fixture.model.shutdown()
    }

    @Test func logoutRemainsAnEditorDraftUntilSaveAndCancellationKeepsTheConnection() async throws {
        let fixture = try EditorFixture()
        let saved = try await fixture.connect()
        let state = try #require(fixture.store.load().first)
        let editor = fixture.editor(saved)
        editor.logout()
        #expect(editor.isLogoutPending && editor.isDirty && editor.canSave)
        #expect(!editor.isConnected)
        #expect(fixture.model.runningGroups.contains(saved.id))
        #expect(try fixture.store.load().first?.profileID == state.profileID)
        #expect(fixture.node.logouts == 0 && !fixture.node.closed)
        #expect(!fixture.library.hosts.isEmpty)
        editor.cancel()
        #expect(!editor.isLogoutPending && editor.isConnected && !editor.isDirty)
        #expect(fixture.model.runningGroups.contains(saved.id))
        #expect(fixture.node.logouts == 0)
        await fixture.model.shutdown()
    }

    @Test func savingLogoutKeepsTheBindingAndEndsOnlyTheLocalEnrollment() async throws {
        let fixture = try EditorFixture()
        let saved = try await fixture.connect()
        let editor = fixture.editor(saved)
        editor.logout()
        editor.draft.name = "Renamed while logging out"
        let updated = try await editor.save()
        #expect(updated.name == editor.draft.name)
        #expect(updated.tailscale == saved.tailscale)
        #expect(fixture.node.logouts == 1 && fixture.node.closed)
        #expect(fixture.model.runningGroups.isEmpty)
        #expect(fixture.library.hosts.isEmpty)
        #expect(try fixture.store.load().isEmpty)
        #expect(!editor.isLogoutPending && !editor.isDirty)
        await fixture.model.shutdown()
    }

    @Test func disablingAfterLogoutRemainsPendingUntilSave() async throws {
        let fixture = try EditorFixture()
        let saved = try await fixture.connect()
        let editor = fixture.editor(saved)
        editor.setEnabled(false)
        #expect(editor.enabled)
        editor.logout()
        editor.setEnabled(false)
        #expect(!editor.enabled)
        #expect(fixture.model.runningGroups.contains(saved.id))
        #expect(fixture.node.logouts == 0)
        let updated = try await editor.save()
        #expect(updated.tailscale == nil)
        #expect(!fixture.model.runningGroups.contains(saved.id))
        #expect(fixture.node.logouts == 1)
        #expect(try fixture.store.load().isEmpty)
        await fixture.model.shutdown()
    }

    @Test(arguments: [false, true])
    func cancellingTheWholeEditKeepsSavedSettingsRegardlessOfEnabled(enabled: Bool) async throws {
        let fixture = try EditorFixture()
        let saved = try await fixture.connect()
        let profileID = try #require(fixture.store.load().first?.profileID)
        let editor = fixture.editor(saved)
        let hostname = editor.hostname
        let controlURL = editor.controlURL
        let exitNodeID = editor.exitNodeID
        editor.logout()
        editor.hostname = "Replacement device"
        editor.controlURL = "https://another.example.com"
        editor.exitNodeID = "other-exit"
        editor.setEnabled(enabled)
        #expect(editor.isLogoutPending)
        editor.cancel()
        let persistedGroup = try #require(fixture.library.group(saved.id))
        let reopened = fixture.editor(persistedGroup)
        #expect(reopened.enabled && reopened.isConnected && !reopened.isLogoutPending && !reopened.isDirty)
        #expect(reopened.hostname == hostname && reopened.controlURL == controlURL && reopened.exitNodeID == exitNodeID)
        #expect(fixture.model.runningGroups.contains(saved.id))
        #expect(try fixture.store.load().first?.profileID == profileID)
        #expect(fixture.node.logouts == 0 && !fixture.node.closed)
        await fixture.model.shutdown()
    }

    @Test(arguments: [false, true])
    func failedLogoutSaveKeepsTheIntentAndTheConnectionForRetry(localFailure: Bool) async throws {
        let fixture = try EditorFixture()
        let saved = try await fixture.connect()
        let editor = fixture.editor(saved)
        editor.draft.name = "Saved edit"
        editor.logout()
        fixture.vault.failSave = !localFailure
        fixture.store.failRemove = localFailure
        await #expect(throws: (any Error).self) { try await editor.save() }
        #expect(editor.isLogoutPending && editor.canSave)
        #expect(fixture.model.runningGroups.contains(saved.id))
        #expect(fixture.node.logouts == 0 && !fixture.node.closed)
        fixture.vault.failSave = false
        fixture.store.failRemove = false
        let updated = try await editor.save()
        #expect(updated.name == "Saved edit")
        #expect(!editor.isLogoutPending && !editor.isDirty)
        #expect(fixture.model.error == nil)
        #expect(fixture.node.logouts == 1)
        #expect(try fixture.store.load().isEmpty)
        await fixture.model.shutdown()
    }

    @Test(arguments: [false, true])
    func replacementLoginKeepsTheOriginalConnectionUntilSave(commit: Bool) async throws {
        let fixture = try EditorFixture()
        let saved = try await fixture.connect()
        let originalProfile = try #require(fixture.store.load().first?.profileID)
        let replacement = EditorNode(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "other.ts.net"))
        fixture.nodes.next = replacement
        let editor = fixture.editor(saved)
        editor.logout()
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        #expect(fixture.node.logouts == 0 && !fixture.node.closed)
        #expect(try fixture.store.load().first?.profileID == originalProfile)
        #expect(fixture.library.group(saved.id)?.tailscale?.network == fixture.node.network)
        if commit {
            let updated = try await editor.save()
            #expect(updated.tailscale?.network == replacement.network)
            try await wait { fixture.node.closed }
            #expect(fixture.node.logouts == 1)
            #expect(!replacement.closed && replacement.logouts == 0)
            #expect(try fixture.store.load().first?.profileID != originalProfile)
            #expect(!editor.isLogoutPending)
        } else {
            editor.cancel()
            try await wait { replacement.closed }
            #expect(fixture.library.group(saved.id)?.tailscale?.network == fixture.node.network)
            #expect(fixture.node.logouts == 0 && !fixture.node.closed)
            #expect(try fixture.store.load().first?.profileID == originalProfile)
        }
        #expect(fixture.model.runningGroups.contains(saved.id))
        await fixture.model.shutdown()
    }

    @Test func repeatedLogoutAndLoginThenDiscardRetainsTheOriginalAndRetiresEveryCandidate() async throws {
        let fixture = try EditorFixture()
        let saved = try await fixture.connect()
        let originalState = try #require(fixture.store.load().first)
        let originalHosts = fixture.library.hosts.map(\.id)
        let editor = fixture.editor(saved)
        let first = EditorNode(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "first.ts.net"))
        let second = EditorNode(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "second.ts.net"))

        editor.logout()
        fixture.nodes.next = first
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        first.holdLogout = true
        editor.logout()
        try await wait { first.logoutContinuation != nil }
        #expect(editor.isLogoutPending && !editor.isConnected)

        fixture.nodes.next = second
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        #expect(first.logouts == 1 && !first.closed)
        #expect(second.logouts == 0 && !second.closed)
        #expect(fixture.library.group(saved.id)?.tailscale == saved.tailscale)
        #expect(try fixture.store.load().first?.profileID == originalState.profileID)

        editor.cancel()
        try await wait { second.closed }
        first.releaseLogout()
        try await wait { first.closed }
        try await wait { (try? fixture.store.pendingCleanupProfiles().isEmpty) == true }
        #expect(first.logouts == 1 && second.logouts == 1)
        #expect(fixture.node.logouts == 0 && !fixture.node.closed)
        #expect(fixture.model.pendingLogin == nil)
        #expect(fixture.model.runningGroups.contains(saved.id))
        #expect(try fixture.store.load().first?.profileID == originalState.profileID)
        #expect(try fixture.store.pendingCleanupProfiles().isEmpty)
        #expect(fixture.library.hosts.map(\.id) == originalHosts)
        let persistedGroup = try #require(fixture.library.group(saved.id))
        let reopened = fixture.editor(persistedGroup)
        #expect(reopened.isConnected && !reopened.isDirty && !reopened.isLogoutPending)
        #expect(reopened.network == fixture.node.network)
        #expect(reopened.hostname == originalState.hostname)
        await fixture.model.shutdown()
    }

    @Test func deferredLogoutCannotEndANewerEnrollmentFromAnotherEditor() async throws {
        let fixture = try EditorFixture()
        let saved = try await fixture.connect()
        let older = fixture.editor(saved)
        older.logout()
        let newer = fixture.editor(saved)
        newer.logout()
        let replacement = EditorNode(network: fixture.node.network)
        fixture.nodes.next = replacement
        newer.login(authKey: nil)
        try await fixture.ready(newer)
        _ = try await newer.save()
        let profile = try #require(fixture.store.load().first?.profileID)
        await #expect(throws: TailscaleConfigurationError.self) { try await older.save() }
        #expect(try fixture.store.load().first?.profileID == profile)
        #expect(fixture.model.runningGroups.contains(saved.id))
        #expect(replacement.logouts == 0 && !replacement.closed)
        older.cancel()
        await fixture.model.shutdown()
    }

    @Test func cloudEditsDuringSaveDoNotGetReplacedByUnchangedFormValues() async throws {
        let fixture = try EditorFixture(existing: true)
        var group = try #require(fixture.library.groups.first)
        let editor = fixture.editor(group)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        fixture.node.holdStatus = true
        let saving = Task { try await editor.save() }
        try await wait { fixture.node.statusContinuation != nil }
        group.name = "Remote rename"
        group.tailscale?.username = "remote-user"
        group.tailscale?.exitNodeID = "remote-exit"
        fixture.library.replacePersistedSnapshot(.init(groups: [group]))
        fixture.node.releaseStatus()
        let saved = try await saving.value
        #expect(saved.name == "Remote rename")
        #expect(saved.tailscale?.username == "remote-user")
        #expect(saved.tailscale?.exitNodeID == "remote-exit")
        #expect(fixture.node.exitNode == "remote-exit")
        await fixture.model.shutdown()
    }

    @Test func changedLoginFieldsCannotBeSilentlyDiscardedBySave() async throws {
        let fixture = try EditorFixture(existing: true)
        let group = try #require(fixture.library.groups.first)
        let editor = fixture.editor(group)
        #expect(editor.canSave)
        editor.controlURL = "https://another.example.com"
        #expect(!editor.canSave)
        editor.controlURL = TailscaleNetwork.defaultControlURL
        editor.hostname = "Another device"
        #expect(!editor.canSave)
        editor.setEnabled(false)
        #expect(editor.canSave)
        await fixture.model.shutdown()
    }

    @Test func disablingAfterPartialSaveCanRemoveThePublishedBinding() async throws {
        let fixture = try EditorFixture()
        let editor = fixture.editor()
        editor.setEnabled(true)
        editor.login(authKey: nil)
        try await fixture.ready(editor)
        fixture.store.failSave = true
        await #expect(throws: (any Error).self) { try await editor.save() }
        editor.setEnabled(false)
        let saved = try await editor.save()
        #expect(saved.tailscale == nil)
        #expect(fixture.library.group(saved.id)?.tailscale == nil)
        await fixture.model.shutdown()
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }
}

@MainActor private final class EditorFixture {
    let library: HostLibraryModel
    let vault: EditorVaultStore
    let store = EditorLocalStore()
    let node: EditorNode
    let nodes: EditorNodes
    let model: TailscaleModel

    init(existing: Bool = false, otherNetwork: Bool = false) throws {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "test.ts.net")
        node = EditorNode(network: network)
        var group = HostGroup(name: "Original")
        group.tailscale = TailscaleGroupConfiguration(
            network: otherNetwork
                ? try TailscaleNetwork(controlURL: "https://old.example.com", dnsSuffix: "old.ts.net") : network)
        group.tailscale?.username = "operator"
        group.tailscale?.exitNodeID = "exit"
        group.tailscale?.hostPreferences[UUID()] = TailscaleHostPreferences()
        vault = EditorVaultStore(.init(groups: existing ? [group] : []))
        library = HostLibraryModel(persistence: vault)
        nodes = EditorNodes(next: node)
        let nodes = nodes
        model = TailscaleModel(
            library: library, store: store, factory: { _, _, _, _ in await nodes.next },
            profileStorage: .init(profiles: { [] }, erase: { _ in }), hostname: { "default-device" },
            hasAccess: { true })
    }

    func connect() async throws -> HostGroup {
        let editor = editor()
        editor.setEnabled(true)
        editor.login(authKey: nil)
        try await ready(editor)
        return try await editor.save()
    }

    func editor(_ group: HostGroup? = nil) -> TailscaleGroupEditor { TailscaleGroupEditor(model: model, group: group) }
    func ready(_ editor: TailscaleGroupEditor) async throws {
        for _ in 0..<200 {
            if editor.pending != nil {
                editor.receiveLogin()
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(editor.pending != nil)
    }
}

@MainActor private final class EditorNodes {
    var next: EditorNode
    init(next: EditorNode) { self.next = next }
}

@MainActor private final class EditorNode: TailscaleNodeSession {
    let network: TailscaleNetwork
    var networkName = "Test Tailnet"
    var hostname = "default-device"
    var exitNode: String?
    var closed = false
    var logouts = 0
    var holdLogout = false
    var logoutContinuation: CheckedContinuation<Void, Never>?
    var holdStatus = false
    var statusContinuation: CheckedContinuation<Void, Never>?
    var peers: [TailscalePeer] {
        [
            TailscalePeer(
                stableID: "exit", name: "Exit", dnsName: "exit.\(network.dnsSuffix)", online: true,
                sshHostKeys: ["fixture"], exitNodeOption: true)
        ]
    }
    init(network: TailscaleNetwork) { self.network = network }
    @MainActor func status() async throws -> TailscaleNodeStatus {
        if holdStatus { await withCheckedContinuation { statusContinuation = $0 } }
        return .init(
            running: true, network: network, authURL: nil, peers: peers,
            device: .init(
                networkName: networkName, dnsName: "device.\(network.dnsSuffix)", hostname: hostname,
                addresses: ["100.64.0.1"], operatingSystem: "macOS", keyExpiry: nil))
    }
    @MainActor func releaseStatus() {
        holdStatus = false
        statusContinuation?.resume()
        statusContinuation = nil
    }
    @MainActor func login() async throws {}
    @MainActor func logout() async throws {
        logouts += 1
        if holdLogout { await withCheckedContinuation { logoutContinuation = $0 } }
    }
    @MainActor func releaseLogout() {
        holdLogout = false
        logoutContinuation?.resume()
        logoutContinuation = nil
    }
    @MainActor func close() async { closed = true }
    @MainActor func setHostname(_ value: String) async throws { hostname = value }
    @MainActor func setExitNode(_ value: String?) async throws { exitNode = value }
    @MainActor func dial(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 { 42 }
    @MainActor func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> { [] }
}

@MainActor private final class EditorLocalStore: TailscaleLocalStoring {
    let base = InMemoryTailscaleLocalStore()
    var failSave = false
    var failRemove = false
    func load() throws -> [TailscaleLocalState] { try base.load() }
    func save(_ state: TailscaleLocalState) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        try base.save(state)
    }
    func remove(groupID: UUID) throws {
        if failRemove { throw CocoaError(.fileWriteUnknown) }
        try base.remove(groupID: groupID)
    }
    func scheduleCleanup(profileID: UUID) throws { try base.scheduleCleanup(profileID: profileID) }
    func pendingCleanupProfiles() throws -> Set<UUID> { try base.pendingCleanupProfiles() }
    func completeCleanup(profileID: UUID) throws { try base.completeCleanup(profileID: profileID) }
}

@MainActor private final class EditorVaultStore: VaultPersisting {
    var snapshot: VaultSnapshot
    var failSave = false
    init(_ snapshot: VaultSnapshot) { self.snapshot = snapshot }
    func load() throws -> VaultSnapshot { snapshot }
    func save(_ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>) throws -> VaultMutationSet {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        return .empty
    }
}
