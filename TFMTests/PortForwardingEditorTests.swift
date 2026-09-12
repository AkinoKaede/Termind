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
    @Test func startingRequiresBothSavedRuleAndSavedHost() {
        let host = Host(name: "Server", host: "server.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        func state(_ candidate: PortForwardingRule?, _ candidateHost: Host, saved: Bool = true)
            -> PortForwardingEditorState
        {
            PortForwardingEditorState(
                rule: candidate, host: candidateHost, savedRule: saved ? rule : nil,
                savedHost: saved ? host : nil, isEnabled: false, runtime: .stopped)
        }
        #expect(state(rule, host).canStart)
        #expect(state(rule, host).canEdit)
        #expect(!state(rule, host, saved: false).canToggle)
        #expect(!state(nil, host).canStart)
        var changedRule = rule
        changedRule.bindPort += 1
        #expect(!state(changedRule, host).canStart)
        var changedHost = host
        changedHost.host = "changed.invalid"
        #expect(!state(rule, changedHost).canToggle)
        let unsavedRule = PortForwardingRule(hostID: host.id)
        #expect(!state(unsavedRule, host).canStart)
        let deletedHost = PortForwardingEditorState(
            rule: rule, host: host, savedRule: rule, savedHost: nil, isEnabled: false, runtime: .stopped)
        #expect(!deletedHost.canStart)
    }

    @Test func allActivePhasesAllowStoppingDirtyDraftsAndLockEditing() {
        let host = Host(name: "Server", host: "server.invalid")
        let phases: [PortForwardingRuntimeState] = [
            .preparing, .awaitingTrust, .awaitingAuthentication, .connecting, .starting,
            .running(activeConnections: 2), .reconnecting(attempt: 1, nextRetry: .now, message: "Retry"),
        ]
        for phase in phases {
            let state = PortForwardingEditorState(
                rule: nil, host: host, savedRule: nil, savedHost: nil, isEnabled: true, runtime: phase)
            #expect(state.canToggle)
            #expect(!state.canStart)
            #expect(!state.canEdit)
        }
        let stopped = PortForwardingEditorState(
            rule: nil, host: host, savedRule: nil, savedHost: nil, isEnabled: false, runtime: .stopped)
        #expect(stopped.canEdit)
        #expect(!stopped.canToggle)
    }

    @Test func failedSavedRulesCanBeEditedAndRetried() {
        let host = Host(name: "Server", host: "server.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        let state = PortForwardingEditorState(
            rule: rule, host: host, savedRule: rule, savedHost: host,
            isEnabled: false, runtime: .failed("Connection refused"))
        #expect(state.canEdit)
        #expect(state.canStart)
        #expect(state.canToggle)
    }

    @Test func normalizationMatchesSavedValuesAndRejectsInvalidFields() throws {
        let host = Host(name: "Server", host: "server.invalid")
        let saved = PortForwardingRule(hostID: host.id)
        var draft = saved
        draft.bindHost = " 127.0.0.1\n"
        draft.targetHost = " localhost "
        let normalized = try #require(PortForwardingEditorState.normalized(draft))
        #expect(normalized == saved)

        for invalidPort in [0, 65_536] {
            var invalidBind = saved
            invalidBind.bindPort = invalidPort
            #expect(PortForwardingEditorState.normalized(invalidBind) == nil)

            var invalidTarget = saved
            invalidTarget.targetPort = invalidPort
            #expect(PortForwardingEditorState.normalized(invalidTarget) == nil)
        }

        var emptyBindHost = saved
        emptyBindHost.bindHost = " \n"
        #expect(PortForwardingEditorState.normalized(emptyBindHost) == nil)

        var emptyTargetHost = saved
        emptyTargetHost.targetHost = " \n"
        #expect(PortForwardingEditorState.normalized(emptyTargetHost) == nil)
    }

    @Test func dynamicDraftDiscardsHiddenTargetValuesBeforeComparingOrSaving() throws {
        let host = Host(name: "Server", host: "server.invalid")
        let saved = PortForwardingRule(hostID: host.id, kind: .dynamic)
        var draft = saved
        draft.targetHost = "old-target.invalid"
        draft.targetPort = 443
        let normalized = try #require(PortForwardingEditorState.normalized(draft))
        #expect(normalized == saved)
        #expect(normalized.targetHost == nil)
        #expect(normalized.targetPort == nil)
    }

    @Test func savingHostAndRuleDoesNotStartForwardingAndOtherWindowEditsInvalidateStart() throws {
        let host = Host(name: "Server", host: "server.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        let library = HostLibraryModel()
        let app = AppModel(hosts: library)
        defer { app.shutdownForTermination() }
        #expect(library.upsert(host, replacingPortForwardings: [rule]))
        // Reopening the host editor reloads persisted metadata, including its assigned sort index.
        let savedHost = try #require(library.host(host.id))
        let state = PortForwardingEditorState(ruleID: rule.id, rule: rule, host: savedHost, app: app)
        #expect(state.canStart)
        #expect(!app.forwarding.isEnabled(rule.id))
        #expect(app.forwarding.state(for: rule.id) == .stopped)
        var remotelyChanged = rule
        remotelyChanged.bindPort = 9000
        library.upsert(remotelyChanged)
        #expect(!PortForwardingEditorState(ruleID: rule.id, rule: rule, host: savedHost, app: app).canStart)
    }
}
