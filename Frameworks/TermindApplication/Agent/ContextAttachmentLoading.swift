// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Bounded attachment decoding is supplied by Infrastructure, never by a view.
public nonisolated struct ContextAttachmentLoading: Sendable {
    public static let maximumAttachments = 20
    public var file: @Sendable (URL) async throws -> ContextChip
    public var image: @Sendable (Data, String) async throws -> ContextChip

    public init(
        file: @escaping @Sendable (URL) async throws -> ContextChip,
        image: @escaping @Sendable (Data, String) async throws -> ContextChip
    ) {
        self.file = file
        self.image = image
    }

    public static let unavailable = Self(
        file: { _ in throw CancellationError() }, image: { _, _ in throw CancellationError() })
}
