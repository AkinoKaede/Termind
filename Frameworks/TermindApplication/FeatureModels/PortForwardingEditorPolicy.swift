import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Shared edit and start policy for the platform-specific forwarding editors.
public nonisolated struct PortForwardingEditorPolicy {
    public let hasSavedConfiguration: Bool
    public let isEnabled: Bool
    public let isRuntimeActive: Bool

    public var canStart: Bool { hasSavedConfiguration && !isEnabled && !isRuntimeActive }
    public var canToggle: Bool { true }
    public var canEdit: Bool { !isRuntimeActive }
    public var isWaitingForSave: Bool { isEnabled && !hasSavedConfiguration && !isRuntimeActive }

    public init(
        rule: PortForwardingRule?,
        savedRule: PortForwardingRule?, savedHost: Host?,
        isEnabled: Bool, isRuntimeActive: Bool
    ) {
        hasSavedConfiguration =
            savedRule?.isValid == true && savedRule?.hostID == savedHost?.id
            && (rule == nil || rule?.id == savedRule?.id)
        self.isEnabled = isEnabled
        self.isRuntimeActive = isRuntimeActive
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
