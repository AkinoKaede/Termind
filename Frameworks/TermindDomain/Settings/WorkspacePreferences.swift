// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated struct WorkspacePreferences: Codable, Hashable, Sendable {
    public var automaticallyRenamesWorkspaces = true

    public init(automaticallyRenamesWorkspaces: Bool = true) {
        self.automaticallyRenamesWorkspaces = automaticallyRenamesWorkspaces
    }
}

public nonisolated enum WorkspaceNameAllocator {
    public static func nextName(
        prefix: String,
        occupiedNames: some Sequence<String>,
        automaticallyRenames: Bool
    ) -> String {
        guard automaticallyRenames else { return prefix }

        let occupied = Set(occupiedNames)
        guard occupied.contains(prefix) else { return prefix }

        let numberedPrefix = prefix + " ("
        let maximum =
            occupied.lazy.compactMap { name -> Int? in
                guard name.hasPrefix(numberedPrefix), name.hasSuffix(")") else { return nil }
                let suffix = name.dropFirst(numberedPrefix.count).dropLast()
                guard !suffix.isEmpty,
                    suffix.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                    let value = Int(suffix), value < Int.max
                else { return nil }
                return value
            }.max() ?? 0
        return "\(prefix) (\(maximum + 1))"
    }
}
