import Foundation
import TermindApplication
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
        let shared = PortForwardingEditorPolicy(
            rule: rule, host: host, savedRule: savedRule, savedHost: savedHost,
            isEnabled: isEnabled, isRuntimeActive: runtime.isActive)
        hasSavedConfiguration = shared.hasSavedConfiguration
        self.isEnabled = shared.isEnabled
        self.runtime = runtime
    }

    init(ruleID: PortForwardingRule.ID, rule: PortForwardingRule?, host: Host, app: AppModel) {
        self.init(
            rule: rule, host: host,
            savedRule: app.forwardings.portForwarding(ruleID), savedHost: app.hostLibrary.host(host.id),
            isEnabled: app.forwarding.isEnabled(ruleID), runtime: app.forwarding.state(for: ruleID))
    }

    static func normalized(_ rule: PortForwardingRule) -> PortForwardingRule? {
        PortForwardingEditorPolicy.normalized(rule)
    }

}
