// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated protocol WakeOnLANSending: Sendable {
    /// Sends a small datagram on the current physical LAN, without waiting for the remote machine.
    func send(to address: MACAddress) throws
}

public nonisolated enum WakeOnLANError: Error, Sendable {
    case invalidAddress
    case noLocalNetwork
    case sendFailed(Int32)
}

public typealias ConnectionWakeAction = @Sendable () async -> Void

/// One instance per application process; access is checked at execution, never cached in a connection snapshot.
@MainActor
public final class WakeOnLANController {
    private let sender: any WakeOnLANSending
    private let now: @MainActor () -> TimeInterval
    private var lastAutomaticSend: [MACAddress: TimeInterval] = [:]
    public var reportAutomaticFailure: ((any Error) -> Void)?

    public init(
        sender: any WakeOnLANSending,
        now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.sender = sender
        self.now = now
    }

    public func wake(_ preferences: WakeOnLANPreferences) throws {
        try Task.checkCancellation()
        guard let address = preferences.address else { throw WakeOnLANError.invalidAddress }
        try sender.send(to: address)
    }

    public func automaticallyWake(_ preferences: WakeOnLANPreferences) {
        guard !Task.isCancelled, preferences.automaticallyWake,
            let address = preferences.address
        else { return }
        let instant = now()
        if let previous = lastAutomaticSend[address], instant - previous < 3 { return }
        lastAutomaticSend = lastAutomaticSend.filter { instant - $0.value < 3 }
        lastAutomaticSend[address] = instant
        do {
            try wake(preferences)
        } catch {
            reportAutomaticFailure?(error)
        }
    }
}
