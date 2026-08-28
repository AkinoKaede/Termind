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
        window.showsSidebar = false

        window.setDetailSelection(
            [.host(first), .host(second), .host(first), .key(UUID())],
            for: .hosts
        )

        #expect(window.detailSelection(for: .hosts) == [.host(first), .host(second)])
        #expect(window.sidebarMode == .navigation)
        #expect(!window.showsSidebar)
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
    func snippetFeatureStateOwnsPackageSelection() {
        let first = SnippetsPageState()
        let second = SnippetsPageState()
        let package = UUID()

        first.selectedPackageID = package

        #expect(first.selectedPackageID == package)
        #expect(second.selectedPackageID == nil)
    }

    @Test
    func hostAttachedContentOverridesRememberedManagerSelection() {
        let pageHostID = UUID()
        let sftpHost = Host(name: "SFTP", host: "sftp.example")
        let sftpWorkspace = Workspace.sftpSession(host: sftpHost)
        let window = WindowModel(workspaces: [sftpWorkspace], vaultDestination: .hosts)
        window.selectDetail(.host(pageHostID), on: .hosts)

        window.select(sftpWorkspace.id)
        window.selectedWorkspaceID = sftpWorkspace.id
        #expect(window.activeDetailSelection == [.host(sftpHost.id)])

        window.openPage(.hosts)
        #expect(window.activeDetailSelection == [.host(pageHostID)])
    }

    @Test
    func pruningRemovesDeletedObjectsWithoutTouchingValidOnes() {
        let host = Host(name: "Host", host: "host.example")
        let key = SSHKeyRef(label: "Key")
        let identity = Identity(name: "Identity", username: "user")
        let store = HostLibraryModel(hosts: [host], keys: [key], identities: [identity])
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

    @Test
    func sidebarModesAdaptToTheSelectedTopLevelContent() {
        let host = Host(name: "SSH", host: "ssh.example")
        let workspace = Workspace.sshSession(host: host)
        let window = WindowModel(workspaces: [workspace])

        #expect(window.availableSidebarModes == [.navigation, .assistant, .snippets, .history])
        #expect(window.isSidebarModeEnabled(.navigation))
        #expect(window.isSidebarModeEnabled(.history))

        window.selectVault()
        #expect(window.availableSidebarModes == [.navigation, .assistant, .snippets, .history])
        #expect(window.sidebarMode == .navigation)

        window.selectAssistant()
        #expect(window.availableSidebarModes == [.navigation, .assistant, .snippets, .history])
        #expect(window.sidebarMode == .navigation)
    }

    @Test
    func sidebarModeIsSharedAcrossAllDestinations() {
        let first = Workspace.sshSession(host: Host(name: "First", host: "first.example"))
        let second = Workspace.sshSession(host: Host(name: "Second", host: "second.example"))
        let window = WindowModel(workspaces: [first, second])

        window.sidebarMode = .history
        window.select(second.id)
        #expect(window.sidebarMode == .history)

        window.selectVault()
        #expect(window.sidebarMode == .history)

        window.selectAssistant()
        #expect(window.sidebarMode == .history)

        window.sidebarMode = .navigation
        window.openPage(.keychain)
        #expect(window.selectedDestination == .vault)
        #expect(window.vaultDestination == .keychain)
        #expect(window.sidebarMode == .navigation)
    }

    @Test
    func globalModesRemainSelectedWithoutAnSSHFocus() {
        let state = WindowSidebarState()

        for mode in [WindowSidebarState.Mode.snippets, .history] {
            state.mode = mode
            state.reconcileMode()

            #expect(state.mode == mode)
        }
    }

    @Test
    func sftpEnablesAllFourSidebarModes() {
        let workspace = Workspace.sftpSession(
            host: Host(name: "Files", host: "files.example")
        )
        let window = WindowModel(workspaces: [workspace])

        #expect(window.availableSidebarModes == [.navigation, .assistant, .snippets, .history])
        #expect(window.isSidebarModeEnabled(.navigation))
        #expect(window.isSidebarModeEnabled(.assistant))
        #expect(window.isSidebarModeEnabled(.snippets))
        #expect(window.isSidebarModeEnabled(.history))
    }

    @Test
    func showAssistantIsIdempotentAndOpensSidebar() {
        let workspace = Workspace.sftpSession(
            host: Host(name: "Files", host: "files.example")
        )
        let window = WindowModel(workspaces: [workspace])
        window.showsSidebar = false
        window.sidebarMode = .assistant

        window.showAssistant()
        window.showAssistant()

        #expect(window.showsSidebar)
        #expect(window.sidebarMode == .assistant)
    }

    @Test
    func topLevelSwitchDoesNotChangeSidebarVisibility() {
        let workspace = Workspace.sshSession(host: Host(name: "SSH", host: "ssh.example"))
        let window = WindowModel(workspaces: [workspace])

        window.showsSidebar = false
        window.selectVault()
        window.selectAssistant()
        window.select(workspace.id)
        #expect(!window.showsSidebar)

        window.showsSidebar = true
        window.selectVault()
        #expect(window.showsSidebar)
    }
}
