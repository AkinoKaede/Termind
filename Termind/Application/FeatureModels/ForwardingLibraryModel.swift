import Foundation

/// Read and write access needed by the port-forwarding feature.
@Observable
final class ForwardingLibraryModel {
    let library: HostLibraryModel

    init(library: HostLibraryModel) {
        self.library = library
    }

    var portForwardings: [PortForwardingRule] { library.portForwardings }

    func portForwarding(_ id: PortForwardingRule.ID) -> PortForwardingRule? {
        library.portForwarding(id)
    }
    func routeSummary(for host: Host) -> String { library.routeSummary(for: host) }
    func sshCommand(for host: Host) -> String? { library.sshCommand(for: host) }
    func sshCommand(for rule: PortForwardingRule, host: Host? = nil) -> String? {
        library.sshCommand(for: rule, host: host)
    }
    func upsert(_ forwarding: PortForwardingRule) { library.upsert(forwarding) }
    func delete(portForwardingID: PortForwardingRule.ID) {
        library.delete(portForwardingID: portForwardingID)
    }
    func duplicate(portForwardingID: PortForwardingRule.ID) -> PortForwardingRule? {
        library.duplicate(portForwardingID: portForwardingID)
    }
}
