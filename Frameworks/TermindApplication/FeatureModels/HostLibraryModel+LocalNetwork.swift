import TermindDomain

import struct TermindDomain.Host

public nonisolated enum HostWakeOutcome: Equatable, Sendable {
    case accessDenied
    case configurationRequired
    case sent
    case failed
}

extension HostLibraryModel {
    /// Request access before configuration, then read the latest saved preferences.
    public func requestWake(_ proposed: Host, requestAccess: () -> Bool) -> HostWakeOutcome {
        guard requestAccess() else { return .accessDenied }
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
