import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct HostAdmissionTests {
    private func fixtures() -> [Host] {
        var hosts = (0..<4).map {
            Host(
                name: "Host\($0)", host: "host\($0).invalid",
                createdAt: Date(timeIntervalSince1970: Double($0)), telnetEnabled: true)
        }
        hosts[0].jumpHostID = hosts[3].id
        return hosts
    }

    @Test(arguments: [EntitlementStatus.free, .loading])
    func telnetSingleBatchAndQuickConnectIgnoreTheSSHJump(status: EntitlementStatus) throws {
        let hosts = fixtures()
        let app = AppModel(hosts: HostLibraryModel(hosts: hosts), proAccess: .testing(status: status))
        let window = WindowModel()
        defer {
            window.closeAll()
            app.shutdownForTermination()
        }
        app.hostLibrary.resolveInitialHostEntitlement = { Issue.record("The Telnet target is already admitted") }
        let opened = app.open(hosts[0], as: .telnetSession, in: window)
        #expect(opened?.focusedPane.telnetSession != nil)
        app.open([hosts[0], hosts[1]], as: .telnetSession, layout: .oneWorkspace, in: window)
        #expect(window.workspaces.last?.panes.map(\.hostID) == [hosts[0].id, hosts[1].id])
        guard case .connection(let input) = QuickConnectParser.parse("telnet Host0 2323") else {
            Issue.record("Expected a Telnet command")
            return
        }
        let target = try QuickConnectResolver.resolve(input, in: app.hostLibrary)
        let quick = app.openQuickConnect(target, in: window)
        #expect(quick?.focusedPane.telnetSession != nil)
        #expect(!app.proAccess.isPaywallPresented)

        app.hostLibrary.hostAccess.entitlement = .free
        let before = window.workspaces.count
        let ssh = app.open(hosts[0], as: .sshSession, in: window)
        let sftp = app.open(hosts[0], as: .sftpChannel, in: window)
        let lockedTelnet = app.open(hosts[3], as: .telnetSession, in: window)
        #expect(ssh == nil && sftp == nil && lockedTelnet == nil)
        #expect(window.workspaces.count == before)
        #expect(app.proAccess.isPaywallPresented)
    }

    @Test func unavailableDefaultDoesNotEnterAdmissionOrMarkTheHostConnecting() {
        let host = Host(name: "Disabled", host: "disabled.invalid", sshEnabled: false)
        let app = AppModel(
            hosts: HostLibraryModel(hosts: [host]), proAccess: .testing(status: .verificationFailed))
        let window = WindowModel()
        defer { app.shutdownForTermination() }

        #expect(app.open(host, as: .preferredTerminal, in: window) == nil)
        for layout in [BatchLayout.separateWorkspaces, .oneWorkspace] {
            app.open([host], as: .preferredTerminal, layout: layout, in: window)
        }
        #expect(window.workspaces.isEmpty)
        #expect(window.hostAccessError == nil)
        #expect(!app.proAccess.isPaywallPresented)
        #expect(app.hostLibrary.status(of: host.id) == .disconnected)
    }

    @Test func loadingBatchWaitsBeforeOpeningAnyTelnetPanes() async throws {
        let hosts = fixtures()
        let app = AppModel(hosts: HostLibraryModel(hosts: hosts), proAccess: .testing(status: .loading))
        let window = WindowModel()
        defer {
            window.closeAll()
            app.shutdownForTermination()
        }
        var continuation: CheckedContinuation<Void, Never>?
        app.hostLibrary.resolveInitialHostEntitlement = {
            await withCheckedContinuation { continuation = $0 }
            app.hostLibrary.hostAccess.entitlement = .purchased(.purchased)
        }
        defer { app.hostLibrary.resolveInitialHostEntitlement = nil }
        app.open([hosts[0], hosts[3]], as: .telnetSession, layout: .oneWorkspace, in: window)
        for _ in 0..<200 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(continuation != nil)
        #expect(window.workspaces.isEmpty)
        continuation?.resume()
        for _ in 0..<200 where window.workspaces.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(window.workspaces.count == 1)
        #expect(window.workspaces.first?.panes.map(\.hostID) == [hosts[0].id, hosts[3].id])
        #expect(!app.proAccess.isPaywallPresented)
    }

    @Test(arguments: [EntitlementStatus.purchased(.purchased), .free, .verificationFailed])
    func duplicateWaitsAndPresentsOnlyTheApplicableAccessOutcome(status: EntitlementStatus) async throws {
        let hosts = Array(fixtures().prefix(3))
        let app = AppModel(hosts: HostLibraryModel(hosts: hosts), proAccess: .testing(status: .loading))
        let window = WindowModel()
        defer { app.shutdownForTermination() }
        var continuation: CheckedContinuation<Void, Never>?
        app.hostLibrary.resolveInitialHostEntitlement = {
            await withCheckedContinuation { continuation = $0 }
            app.hostLibrary.hostAccess.entitlement = status
        }
        defer { app.hostLibrary.resolveInitialHostEntitlement = nil }
        let operation = Task { await HostMenuEntries.duplicate(hosts[1], in: app, window: window) }
        for _ in 0..<200 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(continuation != nil)
        #expect(app.hostLibrary.hosts == hosts)
        continuation?.resume()
        await operation.value
        #expect(app.hostLibrary.hosts.count == (status.hasProAccess ? 4 : 3))
        #expect(app.proAccess.isPaywallPresented == (status == .free))
        #expect(
            window.hostAccessError
                == (status == .verificationFailed
                    ? HostAccessError.entitlementVerificationFailed.localizedDescription : nil))
    }
}
