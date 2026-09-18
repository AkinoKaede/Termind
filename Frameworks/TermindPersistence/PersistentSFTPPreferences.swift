import Foundation
import SwiftData
import TermindApplication
import TermindDomain

@Model
public final class PersistentSFTPPreferences {
    @Attribute(.unique) public var key = "default"
    public var data = Data()

    public init(_ value: SFTPPreferences) throws { try apply(value) }
    public func load() throws -> SFTPPreferences { try JSONDecoder().decode(SFTPPreferences.self, from: data) }
    public func apply(_ value: SFTPPreferences) throws { data = try JSONEncoder().encode(value.normalized) }
}

extension SFTPPreferences {
    public init(defaults: UserDefaults) {
        self.init(
            globalLimit: defaults.object(forKey: SettingsKey.sftpGlobalTransferLimit) as? Int
                ?? Self.defaultGlobalLimit,
            perHostLimit: defaults.object(forKey: SettingsKey.sftpPerHostTransferLimit) as? Int
                ?? Self.defaultPerHostLimit)
    }

    public func mirror(to defaults: UserDefaults) {
        defaults.set(globalLimit, forKey: SettingsKey.sftpGlobalTransferLimit)
        defaults.set(perHostLimit, forKey: SettingsKey.sftpPerHostTransferLimit)
    }
}
