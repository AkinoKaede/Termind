import AppKit
import Testing

@testable import Termind

@MainActor
struct AppAppearanceTests {
    @Test
    func missingAndInvalidPreferencesFollowSystem() throws {
        try withDefaults { defaults in
            #expect(AppAppearance.stored(in: defaults) == .system)
            defaults.set("unsupported", forKey: DesktopSettingsKey.appAppearance)
            #expect(AppAppearance.stored(in: defaults) == .system)
            defaults.set(42, forKey: DesktopSettingsKey.appAppearance)
            #expect(AppAppearance.stored(in: defaults) == .system)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "AppAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
