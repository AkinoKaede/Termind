import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite
struct PortForwardingEditorPolicyTests {
    @Test(arguments: [false, true], [false, true])
    func onlySavedStoppedRulesCanStart(hasSavedConfiguration: Bool, isActive: Bool) {
        let host = Host(name: "Server", host: "server.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        #expect(
            PortForwardingEditorPolicy.canStart(
                rule.id, savedRule: hasSavedConfiguration ? rule : nil, savedHost: host, isRuntimeActive: isActive)
                == (hasSavedConfiguration && !isActive))
    }

    enum UnavailableConfiguration: CaseIterable {
        case missingRule, missingHost, mismatchedHost, mismatchedRuleID
    }

    @Test(arguments: UnavailableConfiguration.allCases)
    func missingOrMismatchedSavedConfigurationCannotStart(configuration: UnavailableConfiguration) {
        let host = Host(name: "Server", host: "server.invalid")
        let rule = PortForwardingRule(hostID: host.id)
        var savedRule: PortForwardingRule? = rule
        var savedHost: Host? = host
        switch configuration {
        case .missingRule: savedRule = nil
        case .missingHost: savedHost = nil
        case .mismatchedHost: savedHost = Host(name: "Other", host: "other.invalid")
        case .mismatchedRuleID: savedRule?.id = UUID()
        }
        #expect(
            !PortForwardingEditorPolicy.canStart(
                rule.id, savedRule: savedRule, savedHost: savedHost, isRuntimeActive: false))
    }

    @Test(arguments: [0, 65_536])
    func aValidDraftCannotMakeAnInvalidSavedRuleStartable(invalidPort: Int) {
        let host = Host(name: "Server", host: "server.invalid")
        let draft = PortForwardingRule(hostID: host.id)
        var savedRule = draft
        savedRule.bindPort = invalidPort
        #expect(
            !PortForwardingEditorPolicy.canStart(
                draft.id, savedRule: savedRule, savedHost: host, isRuntimeActive: false))
    }
}
