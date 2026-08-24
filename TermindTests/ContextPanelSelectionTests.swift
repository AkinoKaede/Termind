import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct ContextPanelSelectionTests {
    @Test
    func statusBarIsReservedOnlyForWorkPanes() {
        #expect(PaneKind.sshSession.showsStatusBar)
        #expect(PaneKind.sftpSession.showsStatusBar)
        #expect(!PaneKind.empty.showsStatusBar)
    }

    @Test
    func selectionIsOrderedDeduplicatedAndScopedToItsPage() {
        let window = WindowModel()
        let first = UUID()
        let second = UUID()
        window.showsContextPanel = false

        window.setDetailSelection(
            [.host(first), .host(second), .host(first), .key(UUID())],
            for: .hosts
        )

        #expect(window.detailSelection(for: .hosts) == [.host(first), .host(second)])
        #expect(window.contextPanelMode == .details)
        #expect(!window.showsContextPanel)
    }

    @Test
    func toggleSupportsMixedKeyAndIdentitySelection() {
        let window = WindowModel()
        let key = ContextPanelDetailID.key(UUID())
        let identity = ContextPanelDetailID.identity(UUID())

        window.selectDetail(key, on: .keychain)
        window.toggleDetail(identity, on: .keychain)
        #expect(window.detailSelection(for: .keychain) == [key, identity])

        window.toggleDetail(key, on: .keychain)
        #expect(window.detailSelection(for: .keychain) == [identity])
    }

    @Test
    func managerPagesRestoreIndependentSelections() {
        let host = ContextPanelDetailID.host(UUID())
        let key = ContextPanelDetailID.key(UUID())
        let window = WindowModel(vaultDestination: .hosts)

        window.selectDetail(host, on: .hosts)
        window.selectDetail(key, on: .keychain)

        #expect(window.activeDetailSelection == [host])
        window.openPage(.keychain)
        #expect(window.activeDetailSelection == [key])
    }

    @Test
    func hostFeatureStateOwnsGroupSelection() {
        let first = HostsPageState()
        let second = HostsPageState()
        let group = UUID()

        first.selectedGroupID = group

        #expect(first.selectedGroupID == group)
        #expect(second.selectedGroupID == nil)
    }

    @Test
    func hostAttachedContentOverridesRememberedManagerSelection() {
        let pageHostID = UUID()
        let sftpHost = Host(name: "SFTP", host: "sftp.example")
        let sftpWorkspace = Workspace.sftpSession(host: sftpHost)
        let window = WindowModel(tabs: [sftpWorkspace], vaultDestination: .hosts)
        window.selectDetail(.host(pageHostID), on: .hosts)

        window.select(sftpWorkspace.id)
        window.selectedTabID = sftpWorkspace.id
        #expect(window.activeDetailSelection == [.host(sftpHost.id)])

        window.openPage(.hosts)
        #expect(window.activeDetailSelection == [.host(pageHostID)])
    }

    @Test
    func pruningRemovesDeletedObjectsWithoutTouchingValidOnes() {
        let host = Host(name: "Host", host: "host.example")
        let key = SSHKeyRef(label: "Key")
        let identity = Identity(name: "Identity", username: "user")
        let store = HostStore(hosts: [host], keys: [key], identities: [identity])
        let window = WindowModel(vaultDestination: .hosts)
        window.setDetailSelection([.host(host.id), .host(UUID())], for: .hosts)
        window.setDetailSelection(
            [.key(key.id), .identity(UUID()), .identity(identity.id)],
            for: .keychain
        )

        #expect(window.activeDetailSelection(in: store) == [.host(host.id)])
        window.pruneDetailSelections(in: store)

        #expect(window.detailSelection(for: .hosts) == [.host(host.id)])
        #expect(
            window.detailSelection(for: .keychain)
                == [.key(key.id), .identity(identity.id)]
        )
    }
}
