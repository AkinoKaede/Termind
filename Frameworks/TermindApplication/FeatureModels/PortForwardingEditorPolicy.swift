import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Shared validation and start policy for the platform-specific forwarding editors.
public nonisolated enum PortForwardingEditorPolicy {
    public static func canStart(
        _ id: PortForwardingRule.ID, savedRule: PortForwardingRule?, savedHost: Host?, isRuntimeActive: Bool
    ) -> Bool {
        savedRule?.id == id
            && savedRule?.isValid == true
            && savedRule?.hostID == savedHost?.id
            && savedHost?.sshEnabled == true
            && !isRuntimeActive
    }

    public static func normalized(_ rule: PortForwardingRule) -> PortForwardingRule? {
        normalized(
            rule, hostID: rule.hostID, bindPort: String(rule.bindPort),
            targetHost: rule.targetHost ?? "", targetPort: rule.targetPort.map(String.init) ?? "")
    }

    /// Uses the exact save candidate for validation, including hidden dynamic targets.
    public static func normalized(
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
