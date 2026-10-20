// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import Testing

import struct TermindDomain.Host

@testable import TermindIOS

@Suite @MainActor
struct MobileHostAdmissionTests {
    private func makeApp(status: EntitlementStatus, count: Int = 4) throws -> MobileAppModel {
        var hosts = (0..<count).map {
            Host(
                name: "Host\($0)", host: "host\($0).invalid",
                createdAt: Date(timeIntervalSince1970: Double($0)), telnetEnabled: true)
        }
        if count == 4 { hosts[0].jumpHostID = hosts[3].id }
        var dependencies = MobileAppDependencies.testing()
        dependencies.proAccess = .testing(status: status)
        let container = try TermindPersistence.makeContainer(inMemory: true)
        _ = try HostPersistence(context: container.mainContext).save(.init(hosts: hosts))
        dependencies.container = container
        return try MobileAppModel(dependencies: dependencies)
    }

    @Test(arguments: [EntitlementStatus.free, .loading])
    func telnetWorkspaceAndPickerIgnoreTheIndependentSSHJump(status: EntitlementStatus) throws {
        let app = try makeApp(status: status)
        defer {
            app.testWorkspaceSession.closeAll()
            app.metrics.core.shutdown()
            app.outbox.stop()
        }
        let hosts = app.library.hosts.sorted { $0.name < $1.name }
        app.library.resolveInitialHostEntitlement = { Issue.record("The Telnet target is already admitted") }
        let opened = app.testWorkspaceSession.open(hostID: hosts[0].id, kind: .telnet)
        #expect(opened != nil)
        #expect(app.workspaces.first?.descriptor.kind == .telnet)
        let telnet = try #require(app.workspaces.first)
        try telnet.requireTerminalInputAccess()
        let picker = MobileMultiHostPickerModel(library: app.library, useCase: .telnetTerminal, selected: [])
        #expect(picker.hosts.contains { $0.id == hosts[0].id })
        #expect(!app.pro.isPaywallPresented)
        app.library.hostAccess.entitlement = .free
        let before = app.workspaces.count
        let ssh = app.testWorkspaceSession.open(hostID: hosts[0].id, kind: .ssh)
        let sftp = app.testWorkspaceSession.open(hostID: hosts[0].id, kind: .sftp)
        let lockedTelnet = app.testWorkspaceSession.open(hostID: hosts[3].id, kind: .telnet)
        #expect(ssh == nil && sftp == nil && lockedTelnet == nil)
        #expect(app.workspaces.count == before)
        #expect(app.pro.isPaywallPresented)
        let sshInput = MobileWorkspace(
            descriptor: .init(hostID: hosts[0].id, title: hosts[0].name, kind: .ssh), hosts: app.library)
        #expect(throws: HostAccessError.lockedHost(hosts[3].id)) { try sshInput.requireTerminalInputAccess() }
    }

    @Test(arguments: [EntitlementStatus.purchased(.purchased), .free, .verificationFailed])
    func duplicateWaitsAndPresentsOnlyTheApplicableAccessOutcome(status: EntitlementStatus) async throws {
        let app = try makeApp(status: .loading, count: 3)
        defer {
            app.metrics.core.shutdown()
            app.outbox.stop()
        }
        let hosts = app.library.hosts
        var continuation: CheckedContinuation<Void, Never>?
        app.library.resolveInitialHostEntitlement = {
            await withCheckedContinuation { continuation = $0 }
            app.library.hostAccess.entitlement = status
        }
        defer { app.library.resolveInitialHostEntitlement = nil }
        let operation = Task { await app.duplicateHost(hosts[0]) }
        for _ in 0..<200 where continuation == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(continuation != nil)
        #expect(app.library.hosts == hosts)
        continuation?.resume()
        await operation.value
        #expect(app.library.hosts.count == (status.hasProAccess ? 4 : 3))
        #expect(app.pro.isPaywallPresented == (status == .free))
        #expect(
            app.error
                == (status == .verificationFailed
                    ? HostAccessError.entitlementVerificationFailed.localizedDescription : nil))
    }
}
