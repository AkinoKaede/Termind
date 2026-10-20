// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindApplication
import TermindDomain

@Model
public final class PersistentSSHPreferences {
    @Attribute(.unique) public var key = "default"
    public var data = Data()

    public init(_ value: SSHPreferences) throws { try apply(value) }
    public func load() throws -> SSHPreferences { try JSONDecoder().decode(SSHPreferences.self, from: data) }
    public func apply(_ value: SSHPreferences) throws { data = try JSONEncoder().encode(value.normalized) }
}

extension SSHPreferences {
    public init(defaults: UserDefaults) {
        self.init(
            maxSessions: defaults.object(forKey: SettingsKey.sshMaxSessions) as? Int
                ?? Self.defaultMaxSessions)
    }

    public func mirror(to defaults: UserDefaults) {
        defaults.set(maxSessions, forKey: SettingsKey.sshMaxSessions)
    }
}
