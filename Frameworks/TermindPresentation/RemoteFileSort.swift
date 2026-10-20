// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated enum RemoteFileSortField: String, CaseIterable, Sendable {
    case name
    case modified
    case size
    case kind

    public var defaultDirection: RemoteFileSortDirection {
        switch self {
        case .modified, .size: .descending
        case .name, .kind: .ascending
        }
    }
}

public nonisolated enum RemoteFileSortDirection: String, Sendable {
    case ascending
    case descending

    public mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

public nonisolated struct RemoteFileSortDescriptor: Sendable {
    public var field: RemoteFileSortField
    public var direction: RemoteFileSortDirection

    public init(field: RemoteFileSortField = .name, direction: RemoteFileSortDirection = .ascending) {
        self.field = field
        self.direction = direction
    }

    public func precedes(
        _ lhs: RemoteFile, _ rhs: RemoteFile,
        lhsKind: String? = nil, rhsKind: String? = nil
    ) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        let primary = compare(lhs, rhs, lhsKind: lhsKind, rhsKind: rhsKind)
        if primary != .orderedSame {
            return direction == .ascending
                ? primary == .orderedAscending
                : primary == .orderedDescending
        }
        let name = lhs.name.localizedStandardCompare(rhs.name)
        if name != .orderedSame { return name == .orderedAscending }
        return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
    }

    private func compare(
        _ lhs: RemoteFile, _ rhs: RemoteFile,
        lhsKind: String?, rhsKind: String?
    ) -> ComparisonResult {
        switch field {
        case .name:
            return lhs.name.localizedStandardCompare(rhs.name)
        case .modified:
            switch (lhs.modifiedAt, rhs.modifiedAt) {
            case (.none, .none): return .orderedSame
            case (.none, .some): return direction == .ascending ? .orderedDescending : .orderedAscending
            case (.some, .none): return direction == .ascending ? .orderedAscending : .orderedDescending
            case (.some(let left), .some(let right)):
                return left == right
                    ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            }
        case .size:
            return lhs.size == rhs.size
                ? .orderedSame
                : (lhs.size < rhs.size ? .orderedAscending : .orderedDescending)
        case .kind:
            return (lhsKind ?? lhs.sftpKindDescription)
                .localizedStandardCompare(rhsKind ?? rhs.sftpKindDescription)
        }
    }
}
