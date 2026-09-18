import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct PortForwardingEditorTests {
    @Test func savedConfigurationIsIndependentFromTheCurrentDraft() {
        let host = Host(name: "Server", host: "server.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        let library = HostLibraryModel(hosts: [host])
        func state(_ candidate: PortForwardingRule?, _ candidateHost: Host, saved: Bool = true)
            -> PortForwardingEditorPolicy
        {
            PortForwardingEditorPolicy(
                rule: candidate, savedRule: saved ? rule : nil,
                savedHost: saved ? library.host(candidateHost.id) : nil,
                isRuntimeActive: false)
        }
        #expect(state(rule, host).canStart)
        #expect(state(rule, host).canEdit)
        // A nil normalized draft can still use the matching saved configuration.
        #expect(state(nil, host).canStart)
        var changedRule = rule
        changedRule.bindPort += 1
        #expect(state(changedRule, host).canStart)
        var changedHost = host
        changedHost.host = "changed.invalid"
        #expect(state(rule, changedHost).canStart)
        changedHost.id = UUID()
        #expect(!state(rule, changedHost).canStart)
        let unsavedRule = PortForwardingRule(hostID: host.id)
        #expect(!state(unsavedRule, host).canStart)
        let deletedHost = PortForwardingEditorPolicy(
            rule: rule, savedRule: rule, savedHost: nil,
            isRuntimeActive: PortForwardingRuntimeState.stopped.isActive)
        #expect(!deletedHost.canStart)
    }

    @Test
    func allActivePhasesLockEditing() {
        let phases: [PortForwardingRuntimeState] = [
            .preparing, .awaitingTrust, .awaitingAuthentication, .connecting, .starting,
            .running(activeConnections: 2),
        ]
        for phase in phases {
            let state = PortForwardingEditorPolicy(
                rule: nil, savedRule: nil, savedHost: nil, isRuntimeActive: phase.isActive)
            #expect(!state.canStart)
            #expect(!state.canEdit)
        }
        let stopped = PortForwardingEditorPolicy(
            rule: nil, savedRule: nil, savedHost: nil,
            isRuntimeActive: PortForwardingRuntimeState.stopped.isActive)
        #expect(stopped.canEdit)
    }

    @Test func failedSavedRulesCanBeEditedAndRetried() {
        let host = Host(name: "Server", host: "server.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        let state = PortForwardingEditorPolicy(
            rule: rule, savedRule: rule, savedHost: host,
            isRuntimeActive: PortForwardingRuntimeState.failed("Connection refused").isActive)
        #expect(state.canEdit)
        #expect(state.canStart)
    }

    @Test(arguments: [PortForwardingRule.Kind.local, .remote])
    func normalizationMatchesSavedValuesAndRejectsInvalidFields(kind: PortForwardingRule.Kind) throws {
        let host = Host(name: "Server", host: "server.invalid")
        let saved = PortForwardingRule(hostID: host.id, kind: kind)
        var draft = saved
        draft.bindHost = " 127.0.0.1\n"
        draft.targetHost = " localhost "
        let normalized = try #require(PortForwardingEditorPolicy.normalized(draft))
        #expect(normalized == saved)

        for validPort in [1, 65_535] {
            var boundary = saved
            boundary.bindPort = validPort
            boundary.targetPort = validPort
            #expect(PortForwardingEditorPolicy.normalized(boundary) == boundary)
        }
        for invalidPort in [0, 65_536] {
            var invalidBind = saved
            invalidBind.bindPort = invalidPort
            #expect(PortForwardingEditorPolicy.normalized(invalidBind) == nil)

            var invalidTarget = saved
            invalidTarget.targetPort = invalidPort
            #expect(PortForwardingEditorPolicy.normalized(invalidTarget) == nil)
        }

        var emptyBindHost = saved
        emptyBindHost.bindHost = " \n"
        #expect(PortForwardingEditorPolicy.normalized(emptyBindHost) == nil)

        var emptyTargetHost = saved
        emptyTargetHost.targetHost = " \n"
        #expect(PortForwardingEditorPolicy.normalized(emptyTargetHost) == nil)
        emptyTargetHost.targetHost = nil
        #expect(PortForwardingEditorPolicy.normalized(emptyTargetHost) == nil)
        var missingTargetPort = saved
        missingTargetPort.targetPort = nil
        #expect(PortForwardingEditorPolicy.normalized(missingTargetPort) == nil)
    }

    @Test(arguments: [0, 443, 65_536])
    func dynamicDraftDiscardsHiddenTargetValuesBeforeComparingOrSaving(hiddenTargetPort: Int) throws {
        let host = Host(name: "Server", host: "server.invalid")
        let saved = PortForwardingRule(hostID: host.id, kind: .dynamic)
        var draft = saved
        draft.targetHost = "old-target.invalid"
        draft.targetPort = hiddenTargetPort
        let normalized = try #require(PortForwardingEditorPolicy.normalized(draft))
        #expect(normalized == saved)
        #expect(normalized.targetHost == nil)
        #expect(normalized.targetPort == nil)
    }

    @Test func savingHostAndRuleDoesNotStartForwardingAndLaterSavedEditsRemainStartable() throws {
        let host = Host(name: "Server", host: "server.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        let library = HostLibraryModel()
        let app = AppModel(hosts: library)
        defer { app.shutdownForTermination() }
        library.upsert(host)
        #expect(library.upsert(rule))
        // Reopening the host editor reloads persisted metadata, including its assigned sort index.
        let savedHost = try #require(library.host(host.id))
        let state = PortForwardingEditorPolicy(
            rule: PortForwardingEditorPolicy.normalized(rule),
            savedRule: app.forwardings.portForwarding(rule.id),
            savedHost: app.hostLibrary.host(savedHost.id),
            isRuntimeActive: app.forwarding.state(for: rule.id).isActive)
        #expect(state.canStart)
        #expect(app.forwarding.state(for: rule.id) == .stopped)
        var remotelyChanged = rule
        remotelyChanged.bindPort = 9000
        library.upsert(remotelyChanged)
        let reopened = PortForwardingEditorPolicy(
            rule: PortForwardingEditorPolicy.normalized(rule),
            savedRule: app.forwardings.portForwarding(rule.id),
            savedHost: app.hostLibrary.host(savedHost.id),
            isRuntimeActive: app.forwarding.state(for: rule.id).isActive)
        #expect(reopened.canStart)
    }
}
