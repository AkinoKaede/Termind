import AppKit
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
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

    @Test
    func appearanceChangesReachMountedAndNewNativeViewsAndClearTheOverride() throws {
        try withDefaults { defaults in
            let notifications = NotificationCenter()
            let parent = NSView()
            let child = NSView()
            parent.addSubview(child)
            let controller = AppAppearanceController(
                defaults: defaults, notifications: notifications,
                apply: { parent.appearance = $0 }
            )
            controller.start()
            defer { controller.stop() }
            #expect(parent.appearance == nil)

            for (selection, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                defaults.set(selection, forKey: DesktopSettingsKey.appAppearance)
                notifications.post(name: UserDefaults.didChangeNotification, object: defaults)
                #expect(parent.appearance?.name == name)
                #expect(child.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name)
                let newChild = NSView()
                parent.addSubview(newChild)
                #expect(newChild.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name)
            }

            defaults.set("system", forKey: DesktopSettingsKey.appAppearance)
            notifications.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(parent.appearance == nil)
            #expect(child.effectiveAppearance == parent.effectiveAppearance)
        }
    }

    @Test
    func relaunchLoadsPersistedChoiceAndObservationHasOneOwner() throws {
        try withDefaults { defaults in
            let notifications = NotificationCenter()
            var applied: [NSAppearance.Name?] = []
            let controller = AppAppearanceController(
                defaults: defaults, notifications: notifications,
                apply: { applied.append($0?.name) }
            )
            defaults.set("dark", forKey: DesktopSettingsKey.appAppearance)
            controller.start()
            controller.start()
            defaults.set(true, forKey: "unrelated.preference")
            notifications.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(applied == [.darkAqua])

            controller.stop()
            defaults.set("light", forKey: DesktopSettingsKey.appAppearance)
            notifications.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(applied == [.darkAqua])

            let relaunched = AppAppearanceController(
                defaults: defaults, notifications: notifications,
                apply: { applied.append($0?.name) }
            )
            relaunched.start()
            #expect(applied == [.darkAqua, .aqua])
            defaults.set("invalid", forKey: DesktopSettingsKey.appAppearance)
            notifications.post(name: UserDefaults.didChangeNotification, object: defaults)
            #expect(applied == [.darkAqua, .aqua, nil])
            relaunched.stop()
        }
    }

    @Test
    func defaultsWritesAutomaticallyUpdateTheAppearance() async throws {
        let suiteName = "AppAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var applied: NSAppearance.Name?
        let controller = AppAppearanceController(defaults: defaults, apply: { applied = $0?.name })
        controller.start()
        defer { controller.stop() }

        defaults.set("dark", forKey: DesktopSettingsKey.appAppearance)
        for _ in 0..<100 where applied != .darkAqua {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(applied == .darkAqua)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suiteName = "AppAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
