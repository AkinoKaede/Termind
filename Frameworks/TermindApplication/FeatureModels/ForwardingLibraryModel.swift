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

    @discardableResult
    public func save(_ rule: PortForwardingRule) throws -> PortForwardingRule {
        guard library.upsert(rule), let saved = library.portForwarding(rule.id) else {
            throw TermindSSHError.library(library.storageError ?? String(localized: "Unable to Save"))
        }
        return saved
    }

    public func delete(_ id: UUID) throws { try delete([id]) }

    public func delete(_ ids: Set<UUID>) throws {
        guard library.deletePortForwardings(ids) else {
            throw TermindSSHError.library(library.storageError ?? String(localized: "Unable to Save"))
        }
    }

    public func search(_ query: String) -> [PortForwardingRule] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rules }
        return rules.filter { rule in
            [
                rule.label, rule.bindAddress, rule.targetHost ?? "", rule.targetPort.map(String.init) ?? "",
                library.host(rule.hostID)?.name ?? "", library.host(rule.hostID)?.displayAddress ?? "",
            ]
            .contains { $0.localizedCaseInsensitiveContains(query) }
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
