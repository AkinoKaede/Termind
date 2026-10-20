// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindApplication
import TermindDomain

import struct TermindDomain.Host

nonisolated enum MobileConnectionProtocol: Hashable {
    case ssh
    case sftp

    var useCase: HostUseCase {
        switch self {
        case .ssh: .preferredTerminal
        case .sftp: .sftp
        }
    }

    func kind(for host: Host) -> ConnectionHistoryEntry.Kind? {
        guard host.supports(useCase.protocolRequirement) else { return nil }
        switch self {
        case .ssh: return .preferredTerminal(for: host)
        case .sftp: return .sftp
        }
    }
}
