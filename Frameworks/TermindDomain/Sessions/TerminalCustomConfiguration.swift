// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated struct TerminalCustomConfiguration: Hashable, Sendable {
    public nonisolated struct Entry: Hashable, Sendable {
        public var key: String
        public var value: String
        public init(key: String, value: String) {
            self.key = key
            self.value = value
        }
    }

    public var entries: [Entry]

    public init(_ text: String) {
        entries = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
            rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=")
            else { return nil }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return Entry(key: key, value: value)
        }
    }
}
