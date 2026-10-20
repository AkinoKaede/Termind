// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated struct NotificationPreferences: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case never, unfocused, always

        public func allows(isFocused: Bool) -> Bool {
            self == .always || (self == .unfocused && !isFocused)
        }
    }

    public enum TerminalDelivery: String, Codable, CaseIterable, Sendable {
        case systemNotifications, bell
    }

    public var isEnabled = true
    public var assistantMode: Mode = .unfocused
    public var terminalMode: Mode = .unfocused
    public var sftpMode: Mode = .unfocused
    public var terminalDelivery: TerminalDelivery = .systemNotifications
    public var terminalMinimumSeconds = 5

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled, assistantMode, terminalMode, sftpMode, terminalDelivery, terminalMinimumSeconds
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decode(Bool.self, forKey: .isEnabled)
        assistantMode = try values.decode(Mode.self, forKey: .assistantMode)
        terminalMode = try values.decode(Mode.self, forKey: .terminalMode)
        sftpMode = try values.decodeIfPresent(Mode.self, forKey: .sftpMode) ?? .unfocused
        terminalDelivery = try values.decode(TerminalDelivery.self, forKey: .terminalDelivery)
        terminalMinimumSeconds = try values.decode(Int.self, forKey: .terminalMinimumSeconds)
    }

    public var isValid: Bool { terminalMinimumSeconds >= 0 }
    public var usesSystemNotifications: Bool {
        isEnabled
            && (assistantMode != .never || sftpMode != .never
                || (terminalMode != .never && terminalDelivery == .systemNotifications))
    }

    public func allowsAssistant(isFocused: Bool) -> Bool {
        isEnabled && assistantMode.allows(isFocused: isFocused)
    }

    public func allowsSFTP(isFocused: Bool) -> Bool {
        isEnabled && sftpMode.allows(isFocused: isFocused)
    }

    public func allowsTerminal(duration: TimeInterval, isFocused: Bool) -> Bool {
        isEnabled && isValid && terminalMode.allows(isFocused: isFocused)
            && duration >= Double(terminalMinimumSeconds)
    }
}
