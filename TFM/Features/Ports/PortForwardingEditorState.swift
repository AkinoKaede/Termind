import Foundation
import TermindDomain
import TermindRemoteInfrastructure

import struct TermindDomain.Host

/// The list and detail use the same saved-configuration gate; stopping never requires a clean draft.
struct PortForwardingEditorState {
    let hasSavedConfiguration: Bool
    let isEnabled: Bool
    let runtime: PortForwardingRuntimeState

    var canStart: Bool { hasSavedConfiguration && !isEnabled && !runtime.isActive }
    var canToggle: Bool { isEnabled || runtime.isActive || canStart }
    var canEdit: Bool { !isEnabled && !runtime.isActive }

    init(
        rule: PortForwardingRule?, host: Host,
        savedRule: PortForwardingRule?, savedHost: Host?,
        isEnabled: Bool, runtime: PortForwardingRuntimeState
    ) {
        hasSavedConfiguration =
            rule != nil && rule?.isValid == true && rule == savedRule && host == savedHost
        self.isEnabled = isEnabled
        self.runtime = runtime
    }

    init(ruleID: PortForwardingRule.ID, rule: PortForwardingRule?, host: Host, app: AppModel) {
        self.init(
            rule: rule, host: host,
            savedRule: app.forwardings.portForwarding(ruleID), savedHost: app.hostLibrary.host(host.id),
            isEnabled: app.forwarding.isEnabled(ruleID), runtime: app.forwarding.state(for: ruleID))
    }

    static func normalized(_ rule: PortForwardingRule) -> PortForwardingRule? {
        normalized(
            rule, hostID: rule.hostID, bindPort: String(rule.bindPort),
            targetHost: rule.targetHost ?? "", targetPort: rule.targetPort.map(String.init) ?? "")
    }

    /// Use the exact save candidate for validation and start eligibility, including hidden dynamic targets.
    static func normalized(
        _ rule: PortForwardingRule, hostID: Host.ID,
        bindPort: String, targetHost: String, targetPort: String
    ) -> PortForwardingRule? {
        guard let port = Int(bindPort.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var value = rule
        value.hostID = hostID
        value.bindHost = value.bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        value.bindPort = port
        value.targetHost = rule.kind == .dynamic ? nil : targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        value.targetPort =
            rule.kind == .dynamic ? nil : Int(targetPort.trimmingCharacters(in: .whitespacesAndNewlines))
        return value.isValid ? value : nil
    }
}
