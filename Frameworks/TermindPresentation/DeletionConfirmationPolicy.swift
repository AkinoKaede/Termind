// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

/// Describes whether a destructive UI action removes one selected item or clears
/// every item represented by the current collection.
public enum DeletionOperationScope: Equatable, Sendable {
    case item
    case clearCollection
}

/// Shared confirmation semantics used by the macOS and iOS presentation layers.
public enum DeletionConfirmationPolicy: Equatable, Sendable {
    /// Protect every deletion, including a single item.
    case always
    /// Let individual rows be removed immediately, but confirm clearing a collection.
    case clearOnly
    /// Perform the destructive action immediately.
    case never

    public func requiresConfirmation(for scope: DeletionOperationScope) -> Bool {
        switch self {
        case .always:
            true
        case .clearOnly:
            scope == .clearCollection
        case .never:
            false
        }
    }
}

/// Product-level categories that keep destructive behavior aligned across platforms.
public enum DeletionContentCategory: Sendable {
    case protectedData
    case recordedContent
    case savedConfiguration
    case transient

    public var confirmationPolicy: DeletionConfirmationPolicy {
        switch self {
        case .protectedData:
            .always
        case .recordedContent, .savedConfiguration:
            .clearOnly
        case .transient:
            .never
        }
    }

    public func requiresConfirmation(for scope: DeletionOperationScope) -> Bool {
        confirmationPolicy.requiresConfirmation(for: scope)
    }
}
