import Foundation
import Observation
import TermindDomain

import struct TermindDomain.Host

public struct KeyExportServices: Sendable {
    public let install: @Sendable ([SSHAuthorizedKeyInstall], SSHConnectionConfiguration) async throws -> Void

    public init(
        install: @escaping @Sendable ([SSHAuthorizedKeyInstall], SSHConnectionConfiguration) async throws -> Void
    ) {
        self.install = install
    }
}

@MainActor
@Observable
public final class KeyExportModel {
    public enum ExportState: Equatable {
        case running
        case succeeded
        case failed(String)
    }

    public let keys: [SSHKeyRef]
    public private(set) var selected: Set<Host.ID> = []
    public private(set) var states: [Host.ID: ExportState] = [:]
    public private(set) var isExporting = false
    public private(set) var isFinished = false
    public private(set) var targets: [Host] = []
    private let credentials: CredentialLibraryModel
    private let services: KeyExportServices

    public init(keys: [SSHKeyRef], credentials: CredentialLibraryModel, services: KeyExportServices) {
        self.keys = keys
        self.credentials = credentials
        self.services = services
    }

    public func updateSelection(_ ids: Set<Host.ID>) {
        guard !isExporting, !isFinished else { return }
        selected = ids
    }

    public func export(to hostIDs: [Host.ID]) async {
        guard !keys.isEmpty, keys.allSatisfy({ !$0.publicKey.isEmpty }), !hostIDs.isEmpty, !isExporting, !isFinished
        else { return }
        selected = Set(hostIDs)
        // Re-read saved destinations before preparing any credentials. Removed hosts
        // are never contacted, and newly unavailable hosts receive an explicit failure.
        targets = credentials.hosts.filter { selected.contains($0.id) }
        selected.formIntersection(targets.map(\.id))
        guard !targets.isEmpty else { return }
        isExporting = true
        var preparations: [(Host.ID, SSHConnectionPreparation)] = []
        for host in targets {
            if let reason = credentials.keyExportUnavailableReason(for: host) {
                states[host.id] = .failed(reason)
                continue
            }
            do {
                preparations.append((host.id, try credentials.prepareSSHConnection(for: host)))
                states[host.id] = .running
            } catch {
                states[host.id] = .failed(error.localizedDescription)
            }
        }
        let exportKeys = keys.map { SSHAuthorizedKeyInstall(publicKey: $0.publicKey, name: $0.label) }
        let install = services.install
        await withTaskGroup(of: (Host.ID, String?).self) { group in
            for (id, preparation) in preparations {
                group.addTask {
                    do {
                        let configuration = try await preparation.resolve()
                        try await install(exportKeys, configuration)
                        return (id, nil)
                    } catch {
                        return (id, error.localizedDescription)
                    }
                }
            }
            for await (id, error) in group {
                states[id] = error.map(ExportState.failed) ?? .succeeded
            }
        }
        isExporting = false
        isFinished = true
    }
}
