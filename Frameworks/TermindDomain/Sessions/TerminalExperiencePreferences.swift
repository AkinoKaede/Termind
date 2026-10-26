// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

/// Device-local mouse, feedback and power preferences, separate from synced terminal appearance.
public nonisolated struct TerminalExperiencePreferences: Equatable, Sendable {
    public var bellSound = false
    public var bellVibration = true
    public var keepScreenAwake = true
    public var copyOnSelect = false
    public var pasteOnRightClick = false

    public init() {}
}
