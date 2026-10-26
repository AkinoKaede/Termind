// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum InputSendShortcut: String, CaseIterable, Sendable {
    case returnKey
    case commandReturn

    public enum Action: Sendable {
        case submit
        case newline
        case system
    }

    public static func stored(in defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: SettingsKey.inputSendShortcut).flatMap(Self.init(rawValue:)) ?? .returnKey
    }

    public func returnAction(
        command: Bool, shift: Bool = false, control: Bool = false, option: Bool = false,
        hasMarkedText: Bool = false
    ) -> Action {
        guard !hasMarkedText, !control, !option else { return .system }
        if shift { return .newline }
        return command == (self == .commandReturn) ? .submit : .newline
    }
}
