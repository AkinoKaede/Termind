// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

/// Search order follows Ghostty and VS Code's terminal find widget. A search
/// starts at the bottom of the buffer, so "previous" moves toward older output.
public nonisolated enum TerminalFindDirection: String, Sendable {
    case previous
    case next
}

public nonisolated enum TerminalFindBinding {
    public static func search(_ query: String) -> String { "search:\(query)" }
    public static func navigate(_ direction: TerminalFindDirection) -> String {
        "navigate_search:\(direction.rawValue)"
    }
    public static let end = "end_search"
}
