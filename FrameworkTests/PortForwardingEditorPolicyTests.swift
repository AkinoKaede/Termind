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
        let policy = PortForwardingEditorPolicy(
            rule: rule, savedRule: hasSavedConfiguration ? rule : nil, savedHost: host,
            isRuntimeActive: isActive)
        #expect(policy.canStart == (hasSavedConfiguration && !isActive))
        #expect(policy.canEdit == !isActive)
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
        let policy = PortForwardingEditorPolicy(
            rule: rule, savedRule: savedRule, savedHost: savedHost,
            isRuntimeActive: false)

        #expect(!policy.hasSavedConfiguration)
        #expect(!policy.canStart)
        #expect(policy.canEdit)
    }

    @Test(arguments: [0, 65_536])
    func aValidDraftCannotMakeAnInvalidSavedRuleStartable(invalidPort: Int) {
        let host = Host(name: "Server", host: "server.invalid")
        let draft = PortForwardingRule(hostID: host.id)
        var savedRule = draft
        savedRule.bindPort = invalidPort
        let policy = PortForwardingEditorPolicy(
            rule: PortForwardingEditorPolicy.normalized(draft), savedRule: savedRule, savedHost: host,
            isRuntimeActive: false)

        #expect(!policy.hasSavedConfiguration)
        #expect(!policy.canStart)
        #expect(policy.canEdit)
    }
}
