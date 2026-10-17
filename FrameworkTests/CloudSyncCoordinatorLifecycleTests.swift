import CloudKit
import Foundation
import Observation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing
import os

@testable import TermindInfrastructure

@Suite @MainActor
struct CloudSyncCoordinatorLifecycleTests {
    @Test
    func categoryAdaptersKeepIndependentBindingsEnginesAndEnvironmentMarkers() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let defaults = UserDefaults(suiteName: "CloudSyncCoordinatorLifecycleTests.\(UUID())")!
        let settingsStore = SettingsSyncPersistence(context: context, defaults: defaults)
        let metricsStore = MetricsSyncPersistence(context: context, defaults: defaults)
        try settingsStore.prepare()
        try metricsStore.prepare()
        let secrets = AISecretStore(context: context, keychain: InMemorySecretStore(), defaults: defaults)
        let networks = (0..<3).map { _ in LifecycleNetwork() }
        let vault = VaultSyncCoordinator(
            context: context, defaults: defaults, environmentIdentifier: "Test",
            makeTransport: { _, _ in networks[0].transport })
        let settings = SettingsSyncCoordinator(
            persistence: settingsStore, secrets: secrets, defaults: defaults, environmentIdentifier: "Test",
            makeTransport: { _, _ in networks[1].transport })
        let metrics = MetricsSyncCoordinator(
            persistence: metricsStore, defaults: defaults, environmentIdentifier: "Test",
            makeTransport: { _, _ in networks[2].transport })
        let drivers = [vault.lifecycle, settings.lifecycle, metrics.lifecycle]
        for driver in drivers { driver.start() }
        for driver in drivers { await driver.operation?.value }
        #expect(Set(drivers.map(\.zoneID)).count == 3)
        #expect(try VaultSyncJournal(context: context).state().boundUserRecordName == "current-user")
        #expect(try settingsStore.journal.state().boundUserRecordName == "current-user")
        #expect(try metricsStore.journal.state().boundUserRecordName == "current-user")
        for key in [
            SettingsKey.vaultSyncEnvironment, SettingsKey.settingsSyncEnvironment, SettingsKey.metricsSyncEnvironment,
        ] {
            #expect(defaults.string(forKey: key) == "Test")
        }
        #expect(secrets.uploadsAuthorized)
        vault.pause()
        #expect(vault.status == .paused)
        #expect(settings.lifecycle.accepts(networks[1].nextEngine))
        #expect(metrics.lifecycle.accepts(networks[2].nextEngine))
        #expect(secrets.uploadsAuthorized)
        let settingsState = try settingsStore.journal.state()
        settingsState.pendingUserRecordName = "replacement-user"
        try context.save()
        let statusChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = settings.status
        } onChange: {
            statusChanged.withLock { $0 = true }
        }
        settings.pause()
        #expect(statusChanged.withLock { $0 })
        #expect(settings.status == .paused)
        #expect(!secrets.uploadsAuthorized)
        settings.confirmAccountSwitchMerge()
        await settings.lifecycle.operation?.value
        // The verified account is still current-user, so the new binding requires fresh consent.
        #expect(settingsState.boundUserRecordName == "replacement-user")
        #expect(settingsState.pendingUserRecordName == "current-user")
        #expect(settings.status == .accountChangeConfirmationRequired)
        #expect(try metricsStore.journal.state().boundUserRecordName == "current-user")
        #expect(!secrets.uploadsAuthorized)
        metrics.pause()
    }

    @Test
    func settingsSecretAuthorizationFollowsSuccessfulFetchAndAccountRetirement() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let defaults = UserDefaults(suiteName: "SettingsLifecycleTests.\(UUID())")!
        let store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        let secrets = AISecretStore(
            context: container.mainContext, keychain: InMemorySecretStore(), defaults: defaults)
        let network = LifecycleNetwork()
        let coordinator = SettingsSyncCoordinator(
            persistence: store, secrets: secrets, defaults: defaults, environmentIdentifier: "Test",
            makeTransport: { _, _ in network.transport })
        network.nextEngine.fetchBody = { throw CKError(.networkFailure) }
        coordinator.start()
        await coordinator.lifecycle.operation?.value
        #expect(!secrets.uploadsAuthorized)
        #expect(network.nextEngine.sendCount == 0)
        network.nextEngine.fetchBody = {}
        coordinator.retry()
        await coordinator.lifecycle.operation?.value
        #expect(secrets.uploadsAuthorized)
        #expect(network.nextEngine.sendCount == 1)
        try coordinator.lifecycle.handleAccountChange(.signOut(previousUser: .init(recordName: "current-user")))
        #expect(!secrets.uploadsAuthorized)
        #expect(!coordinator.lifecycle.accepts(network.nextEngine))
        coordinator.pause()
    }

    @Test(arguments: [false, true])
    func settingsStaleSaveAcknowledgementKeepsTheUpdatedSelectionPending(_ reconcilesLegacy: Bool) async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let domain = "SettingsSeedAcknowledgement.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: SettingsKey.settingsSyncEnabled)
        context.insert(try PersistentTerminalPreferences(.init(darkTheme: "Old Dark")))
        let store = SettingsSyncPersistence(context: context, defaults: defaults)
        try store.prepare()
        let secrets = AISecretStore(context: context, keychain: InMemorySecretStore(), defaults: defaults)
        let network = LifecycleNetwork()
        let coordinator = SettingsSyncCoordinator(
            persistence: store, secrets: secrets, defaults: defaults, environmentIdentifier: "Test",
            makeTransport: { _, _ in network.transport })
        coordinator.start()
        defer { coordinator.pause() }
        await coordinator.lifecycle.operation?.value
        let key = SettingsRecordKey(kind: .terminalThemeSelection, id: "dark")
        let id = CKRecord.ID(recordName: key.recordName, zoneID: coordinator.lifecycle.zoneID)
        let oldRecord = try #require(coordinator.recordToSave(id, engine: network.nextEngine))
        let old = try SettingsSyncCoordinator.envelope(from: oldRecord)
        if reconcilesLegacy {
            let payload = SettingsRecordPayload.terminal(.init(darkTheme: "New Dark"))
            let envelope = SettingsEnvelope(
                key: payload.key, version: .init(modifiedAt: .now, counter: 0, writerID: UUID()), payload: payload)
            let record = try SettingsSyncCoordinator.makeRecord(
                .init(envelope: envelope),
                recordID: .init(recordName: payload.key.recordName, zoneID: coordinator.lifecycle.zoneID))
            try coordinator.receiveRemoteRecords([record])
        } else {
            var library = try store.loadTerminalThemes()
            library.select(.init(appearance: .dark, builtInThemeName: "New Dark"))
            try store.saveTerminalThemes(library)
        }
        let current = try #require(try store.journal.envelope(for: key))
        #expect(current.payload == .terminalThemeSelection(.init(appearance: .dark, builtInThemeName: "New Dark")))
        #expect(current.payload != old.payload)
        #expect((current.version == old.version) == reconcilesLegacy)
        try coordinator.handleSentChanges(.init(savedRecords: [oldRecord], failedRecordSaves: []))
        let pending = try #require(try store.journal.outgoingEntry(for: key))
        #expect(pending.envelope == current)
        #expect(pending.systemFieldsData != nil)
        #expect(network.nextEngine.queued.contains(key.recordName))
        let nextRecord = try #require(coordinator.recordToSave(id, engine: network.nextEngine))
        #expect(try SettingsSyncCoordinator.envelope(from: nextRecord) == current)
        try coordinator.handleSentChanges(.init(savedRecords: [nextRecord], failedRecordSaves: []))
        #expect(try store.journal.outgoingEntry(for: key) == nil)
        #expect(try store.journal.envelope(for: key) == current)
        #expect(!network.nextEngine.queued.contains(key.recordName))
    }
}
