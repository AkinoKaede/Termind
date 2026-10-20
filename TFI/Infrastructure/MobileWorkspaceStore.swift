// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Device-local connection intent and recovery references, never credentials or one-shot commands.
@MainActor
final class MobileWorkspaceStore {
    static let key = "mobile.workspaces.v1"
    static let recentlyClosedKey = "mobile.recentlyClosed.v2"
    static let restorationKey = "mobile.restorableWorkspaces.v1"

    struct Snapshot: Codable, Equatable {
        var version = 1
        var sessions: [String: [MobileWorkspaceDescriptor]] = [:]
    }

    private let defaults: UserDefaults?
    private var canSave = true

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func load() throws -> Snapshot {
        do {
            guard let value = defaults?.object(forKey: Self.restorationKey) else { return Snapshot() }
            guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            try validate(snapshot)
            return snapshot
        } catch {
            canSave = false
            throw error
        }
    }

    func save(_ snapshot: Snapshot) throws {
        guard canSave else { throw CocoaError(.coderReadCorrupt) }
        try validate(snapshot)
        defaults?.set(try JSONEncoder().encode(snapshot), forKey: Self.restorationKey)
    }

    private func validate(_ snapshot: Snapshot) throws {
        let descriptors = snapshot.sessions.values.flatMap { $0 }
        guard snapshot.version == 1, snapshot.sessions.keys.allSatisfy({ !$0.isEmpty }),
            Set(descriptors.map(\.id)).count == descriptors.count
        else { throw CocoaError(.coderReadCorrupt) }
    }

    static func retire(in defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: recentlyClosedKey)
    }
}
