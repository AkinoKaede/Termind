// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindDomain

/// Freeze the V1–V50 snippet entity before adding its color in V51.
public enum TermindSchemaV50SnippetModels {
    @Model
    public final class PersistentSnippet {
        @Attribute(.unique) public var id: UUID = UUID()
        public var title = ""
        public var body = ""
        public var packageID: UUID?
        public var targetHostIDs: [UUID] = []
        public var sortIndex = 0.0

        public init(_ value: Snippet) {
            id = value.id
            apply(value)
        }

        public func apply(_ value: Snippet) {
            title = value.title
            body = value.body
            packageID = value.packageID
            targetHostIDs = value.targetHostIDs
            sortIndex = value.sortIndex
        }
    }

}
