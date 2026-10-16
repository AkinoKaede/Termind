import TermindDomain

import struct TermindDomain.Host

public nonisolated enum HostWakeOutcome: Equatable, Sendable {
    case accessDenied
    case configurationRequired
    case sent
    case failed
}

extension HostLibraryModel {
    /// Lock checks precede configuration and packet transmission.
    public func requestWake(_ proposed: Host) -> HostWakeOutcome {
        guard (try? hostAccess.requireAccess(to: proposed.id, in: hosts)) != nil else { return .accessDenied }
        let host = host(proposed.id) ?? proposed
        guard host.wakeOnLAN.address != nil else { return .configurationRequired }
        do {
            guard let wakeOnLAN else { throw WakeOnLANError.noLocalNetwork }
            try wakeOnLAN.wake(host.wakeOnLAN)
            return .sent
        } catch {
            return .failed
        }
    }
}
