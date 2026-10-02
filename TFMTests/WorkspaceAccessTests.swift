import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct WorkspaceAccessTests {
    nonisolated static let nonProStatuses: [EntitlementStatus] =
        [
            .loading, .free, .verificationFailed,
        ]
        + [ProSubscriptionPhase.billingRetry, .expired, .revoked].map {
            .subscription(
                ProSubscriptionStatus(
                    phase: $0, expiresAt: .distantPast, willAutoRenew: false, ownership: .purchased))
        }

    @Test(arguments: nonProStatuses)
    func splittingFillingAndRearrangingPreserveSessionsWithoutPro(status: EntitlementStatus) throws {
        let fixture = Fixture(status: status)
        defer { fixture.close() }
        let window = fixture.window
        let workspace = window.openSSHSession(host: fixture.first)
        let shell = workspace.focusedPane
        let session = try #require(shell.sshSession)

        window.splitSelected(axis: .vertical)
        let slot = workspace.focusedPane
        #expect(slot.isEmptySlot)
        #expect(workspace.panes.count == 2)
        let source = window.openSFTPChannel(host: fixture.second, initialPath: "/srv/app")
        let browser = source.focusedPane
        window.fill(slot.id, in: workspace.id, withPanesOf: source.id)
        #expect(window.workspaces.count == 1)
        #expect(workspace.panes.map(\.id) == [shell.id, browser.id])

        window.movePane(shell.id, beside: browser.id, axis: .horizontal, side: .after)
        #expect(workspace.panes.map(\.id) == [browser.id, shell.id])
        window.splitSelected(axis: .vertical)
        let nextSlot = workspace.focusedPane
        #expect(nextSlot.isEmptySlot)
        window.movePane(browser.id, into: nextSlot.id)
        #expect(workspace.panes.map(\.id) == [shell.id, browser.id])

        let detached = try #require(window.detachPane(browser.id))
        window.merge(detached.id, into: workspace.id, beside: shell.id, axis: .horizontal, side: .before)
        #expect(workspace.panes.map(\.id) == [browser.id, shell.id])
        #expect(window.workspaces.count == 1)
        #expect(window.pane(shell.id)?.sshSession === session)
        #expect(window.pane(browser.id) === browser)
        #expect(browser.sftpChannel?.path == "/srv/app")
        #expect(session.status == .connecting)

        window.separatePanes(in: workspace.id)
        #expect(window.workspaces.map(\.focusedPane.id) == [browser.id, shell.id])
        fixture.expectNoPaywall()
    }

    @Test(arguments: nonProStatuses)
    func paneAndWorkspaceDuplicationAndBroadcastingAreFree(status: EntitlementStatus) throws {
        let fixture = Fixture(status: status)
        defer { fixture.close() }
        let window = fixture.window
        let workspace = window.openSSHSession(host: fixture.first)
        let original = workspace.focusedPane
        window.duplicateSelected(axis: .horizontal)
        #expect(workspace.panes.count == 2)
        #expect(workspace.panes.map(\.hostID) == [fixture.first.id, fixture.first.id])
        #expect(workspace.focusedPane.sshSession !== original.sshSession)
        #expect(workspace.canBroadcast)
        window.toggleBroadcastInput(in: workspace)
        #expect(workspace.broadcastsInput)

        guard case .split(var branch) = workspace.layout else {
            Issue.record("Expected a duplicated split layout")
            return
        }
        branch.fraction = 0.37
        workspace.layout = .split(branch)
        window.duplicateSelectedInNewWorkspace()
        let copy = try #require(window.selectedWorkspace)
        #expect(copy !== workspace)
        #expect(copy.panes.count == 2)
        #expect(!copy.broadcastsInput)
        #expect(Set(copy.panes.map(\.id)).isDisjoint(with: workspace.panes.map(\.id)))
        guard case .split(let copiedBranch) = copy.layout else {
            Issue.record("Expected the copied split layout")
            return
        }
        #expect(copiedBranch.axis == branch.axis)
        #expect(copiedBranch.fraction == 0.37)
        window.toggleBroadcastInput(in: workspace)
        #expect(!workspace.broadcastsInput)
        fixture.expectNoPaywall()
    }

    @Test(arguments: nonProStatuses)
    func openingCompanionSessionsAndBatchWorkspacesIsFree(status: EntitlementStatus) throws {
        let fixture = Fixture(status: status)
        defer { fixture.close() }
        let window = fixture.window
        let workspace = window.openSSHSession(host: fixture.first)
        #expect(
            window.openSFTPChannel(host: fixture.first, initialPath: "/srv", placement: .currentWorkspace)
                === workspace)
        #expect(workspace.panes.map(\.kind) == [.sshSession, .sftpChannel])
        #expect(workspace.focusedPane.sftpChannel?.path == "/srv")
        #expect(window.openSSHSession(host: fixture.first, placement: .currentWorkspace) === workspace)
        #expect(workspace.panes.map(\.kind) == [.sshSession, .sftpChannel, .sshSession])

        for target in [HostOpenTarget.sshSession, .sftpChannel] {
            fixture.app.open([fixture.first, fixture.second], as: target, layout: .oneWorkspace, in: window)
            let batch = try #require(window.selectedWorkspace)
            #expect(batch !== workspace)
            #expect(batch.panes.map(\.hostID) == [fixture.first.id, fixture.second.id])
            #expect(batch.panes.allSatisfy { $0.kind == (target == .sshSession ? .sshSession : .sftpChannel) })
        }

        let snippet = Snippet(title: "Status", body: "uptime", targetHostIDs: [fixture.first.id, fixture.second.id])
        let previousCount = window.workspaces.count
        fixture.app.execute([snippet], in: window)
        let execution = try #require(window.selectedWorkspace)
        #expect(window.workspaces.count == previousCount + 1)
        #expect(execution.panes.map(\.hostID) == [fixture.first.id, fixture.second.id])
        #expect(execution.panes.allSatisfy { $0.sshSession != nil })
        fixture.expectNoPaywall()
    }

    @Test(arguments: nonProStatuses)
    func localTemplatesCanBeSavedUpdatedAndReopenedWithoutPro(status: EntitlementStatus) throws {
        let fixture = Fixture(status: status)
        defer { fixture.close() }
        let window = fixture.window
        let workspace = try #require(window.openWorkspace([fixture.first, fixture.second], as: .sshSession))
        window.requestSaveWorkspaceTemplate()
        let presentation = try #require(window.presentations.workspaceTemplateName)
        presentation.name = "Fleet"
        window.commitWorkspaceTemplateName()
        let templateID = try #require(workspace.sourceTemplateID)
        #expect(fixture.app.hostLibrary.workspaceTemplate(templateID)?.name == "Fleet")

        guard case .split(var branch) = workspace.layout else {
            Issue.record("Expected a batch split layout")
            return
        }
        branch.fraction = 0.31
        workspace.layout = .split(branch)
        workspace.customTitle = "Operations"
        window.requestSaveWorkspaceTemplate()
        let template = try #require(fixture.app.hostLibrary.workspaceTemplate(templateID))
        #expect(template.name == "Operations")
        let reopened = try #require(window.openWorkspaceTemplate(template))
        #expect(reopened.workspaceTemplateLayout(in: fixture.app.hostLibrary) == template.layout)
        #expect(reopened.customTitle == "Operations")
        #expect(reopened.sourceTemplateID == templateID)

        let missing = WorkspaceTemplate(
            name: "Missing host",
            layout: .split(
                axis: .vertical, fraction: 0.64,
                first: template.layout, second: .pane(.sftp(hostID: UUID()))))
        let restored = try #require(window.openWorkspaceTemplate(missing))
        #expect(restored.panes.map(\.kind) == [.sshSession, .sshSession, .empty])
        #expect(window.workspaceTemplateNotice != nil)
        guard case .split(let restoredBranch) = restored.layout else {
            Issue.record("Expected missing hosts to retain their split layout")
            return
        }
        #expect(restoredBranch.fraction == 0.64)
        #expect(restoredBranch.axis == .vertical)
        fixture.expectNoPaywall()
        #expect(!fixture.access.canUse(.vaultSync))
    }

    private final class Fixture {
        let first = Host(name: "A", host: "a.example")
        let second = Host(name: "B", host: "b.example")
        let access: ProAccessController
        let app: AppModel
        let window = WindowModel()

        init(status: EntitlementStatus) {
            access = .testing(status: status)
            app = AppModel(hosts: HostLibraryModel(hosts: [first, second]), proAccess: access)
            app.registerWindow(window)
        }

        func expectNoPaywall() {
            #expect(!access.hasProAccess)
            #expect(!access.isPaywallPresented)
        }

        func close() {
            window.closeAll()
            app.unregisterWindow(window)
        }
    }
}
