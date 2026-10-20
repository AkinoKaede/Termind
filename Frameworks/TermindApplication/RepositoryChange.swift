// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum RepositoryChangeReason: String, Hashable, Sendable {
    case initial
    case refresh
    case mutation
}

public nonisolated struct RepositoryChange<Value: Sendable>: Sendable {
    public let revision: Int64
    public let value: Value
    public let reason: RepositoryChangeReason
    public init(revision: Int64, value: Value, reason: RepositoryChangeReason) {
        self.revision = revision
        self.value = value
        self.reason = reason
    }

}
