import Foundation
import Observation
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileKeyExportServices: Sendable {
    let install: @Sendable ([SSHAuthorizedKeyInstall], SSHConnectionConfiguration) async throws -> Void
}

@MainActor
@Observable
final class MobileKeyExportModel {
    enum ExportState: Equatable {
        case running
        case succeeded
        case failed(String)
    }

    let key: SSHKeyRef
    private(set) var selected: Set<Host.ID> = []
    private(set) var states: [Host.ID: ExportState] = [:]
    private(set) var isExporting = false
    private(set) var isFinished = false
    private(set) var targets: [Host] = []
    private let credentials: CredentialLibraryModel
    private let services: MobileKeyExportServices

    init(key: SSHKeyRef, credentials: CredentialLibraryModel, services: MobileKeyExportServices) {
        self.key = key
        self.credentials = credentials
        self.services = services
    }

    var summary: LocalizedStringResource {
        let failures = states.values.filter { if case .failed = $0 { true } else { false } }.count
        if failures > 0 {
            return AppStrings.Keychain.exportedFailed(count1: states.count - failures, failures: failures)
        }
        return states.count == 1
            ? AppStrings.Keychain.exportedTo1Host : AppStrings.Keychain.exportedToHosts(states.count)
    }

    func updateSelection(_ ids: Set<Host.ID>) {
        guard !isExporting, !isFinished else { return }
        selected = ids
    }

    func export(to hostIDs: [Host.ID]) async {
        guard !key.publicKey.isEmpty, !hostIDs.isEmpty, !isExporting, !isFinished else { return }
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
        let keys = [SSHAuthorizedKeyInstall(publicKey: key.publicKey, name: key.label)]
        let install = services.install
        await withTaskGroup(of: (Host.ID, String?).self) { group in
            for (id, preparation) in preparations {
                group.addTask {
                    do {
                        let configuration = try await preparation.resolve()
                        try await install(keys, configuration)
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
