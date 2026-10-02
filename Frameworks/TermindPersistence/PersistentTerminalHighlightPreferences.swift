import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentTerminalHighlightPreferences {
    @Attribute(.unique) public var key = "default"
    public var data = Data()

    public init(_ value: TerminalHighlightPreferences) throws { try apply(value) }

    public func load() throws -> TerminalHighlightPreferences {
        let value = try JSONDecoder().decode(TerminalHighlightPreferences.self, from: data)
        guard value.isValid else {
            throw SettingsSyncPersistenceError.invalidEnvelope("v1/terminalHighlighting/default")
        }
        return value
    }

    public func apply(_ value: TerminalHighlightPreferences) throws {
        guard value.isValid else {
            throw SettingsSyncPersistenceError.invalidEnvelope("v1/terminalHighlighting/default")
        }
        data = try JSONEncoder().encode(value)
    }
}
