import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Read and write access needed by the port-forwarding feature.
@Observable
public final class ForwardingLibraryModel {
    private let library: HostLibraryModel

    public init(library: HostLibraryModel) {
        self.library = library
    }

    public var hosts: [Host] { library.hosts }
    public var rules: [PortForwardingRule] { library.portForwardings }

    public func save(_ rule: PortForwardingRule) throws {
        guard rule.isValid, let host = library.host(rule.hostID) else { throw CocoaError(.coderInvalidValue) }
        let rules = library.portForwardings(for: host.id).filter { $0.id != rule.id } + [rule]
        guard library.upsert(host, replacingPortForwardings: rules) else {
            throw TermindSSHError.library(library.storageError ?? String(localized: "Unable to Save"))
        }
    }

    public func delete(_ id: UUID) throws {
        guard let rule = library.portForwarding(id), let host = library.host(rule.hostID) else { return }
        guard
            library.upsert(host, replacingPortForwardings: library.portForwardings(for: host.id).filter { $0.id != id })
        else {
            throw TermindSSHError.library(library.storageError ?? String(localized: "Unable to Save"))
        }
    }

    public func portForwarding(_ id: PortForwardingRule.ID) -> PortForwardingRule? {
        library.portForwarding(id)
    }
    public func routeSummary(for host: Host) -> String { library.routeSummary(for: host) }
    public func sshCommand(for rule: PortForwardingRule, host: Host? = nil) -> String? {
        library.sshCommand(for: rule, host: host)
    }
}
