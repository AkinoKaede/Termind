import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@Suite @MainActor
struct NotificationPreferencesTests {
    @Test func initialAuthorizationIsRequestedOnceAcrossConcurrentScenesAndReactivation() async {
        let model = NotificationSettingsModel()
        let service = InitialAuthorizationService()
        service.holdAuthorization = true
        let firstScene = Task { await model.requestInitialAuthorization(using: service) }
        await service.nextRequest()
        await model.requestInitialAuthorization(using: service)
        #expect(service.requests == [true])
        service.finishRequest()
        await firstScene.value
        await model.requestInitialAuthorization(using: service)
        #expect(service.requests == [true])
    }

    @Test(arguments: [false, true])
    func initialAuthorizationRespectsDisabledNotificationsAndBellOnlyDelivery(bellOnly: Bool) async {
        let store = NotificationStore()
        if bellOnly {
            store.value.assistantMode = .never
            store.value.sftpMode = .never
            store.value.terminalDelivery = .bell
        } else {
            store.value.isEnabled = false
        }
        let model = NotificationSettingsModel(persistence: store)
        let service = InitialAuthorizationService()
        await model.requestInitialAuthorization(using: service)
        #expect(service.requests.isEmpty)
        model.applyRemoteSnapshot(.init())
        await model.requestInitialAuthorization(using: service)
        #expect(service.requests == [true])
    }

    @Test func failedPreferenceLoadDoesNotRequestAuthorizationUsingDefaults() async {
        let store = NotificationStore()
        store.fails = true
        let model = NotificationSettingsModel(persistence: store)
        let service = InitialAuthorizationService()
        await model.requestInitialAuthorization(using: service)
        #expect(model.storageError != nil)
        #expect(service.requests.isEmpty)
    }

    @Test func defaultsAndIndependentModesAndPermissionRequirements() {
        var value = NotificationPreferences()
        #expect(value.isEnabled)
        #expect(value.assistantMode == .unfocused && value.terminalMode == .unfocused)
        #expect(value.sftpMode == .unfocused)
        #expect(value.terminalDelivery == .systemNotifications && value.terminalMinimumSeconds == 5)
        #expect(value.usesSystemNotifications)
        value.isEnabled = true
        value.assistantMode = .never
        value.sftpMode = .never
        value.terminalDelivery = .bell
        #expect(!value.usesSystemNotifications)
        #expect(value.allowsTerminal(duration: 5, isFocused: false))
        #expect(!value.allowsAssistant(isFocused: false))
        value.assistantMode = .always
        value.sftpMode = .always
        value.terminalMode = .never
        #expect(value.usesSystemNotifications)
        #expect(value.allowsAssistant(isFocused: true))
        #expect(!value.allowsTerminal(duration: 100, isFocused: false))
    }

    @Test func invalidOrFailedEditsLeaveTheSavedAndLiveValuesUntouched() {
        let store = NotificationStore()
        let model = NotificationSettingsModel(persistence: store)
        #expect(!model.set(-1, for: \.terminalMinimumSeconds))
        #expect(model.preferences.terminalMinimumSeconds == 5)
        #expect(model.set(0, for: \.terminalMinimumSeconds))
        #expect(model.set(1, for: \.terminalMinimumSeconds))
        store.fails = true
        #expect(!model.set(false, for: \.isEnabled))
        #expect(model.preferences.isEnabled && store.value.isEnabled)
        #expect(model.storageError != nil)
        var remote = NotificationPreferences()
        remote.isEnabled = false
        model.applyRemoteSnapshot(remote)
        #expect(model.preferences == remote && model.storageError == nil)
        #expect(store.value.isEnabled)
    }

    @Test func notificationRecordRoundTripsAndRemoteUpdatesNeverEcho() throws {
        let source = try NotificationFixture()
        let destination = try NotificationFixture()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        var value = NotificationPreferences()
        value.isEnabled = true
        value.assistantMode = .always
        value.terminalMode = .unfocused
        value.terminalDelivery = .bell
        value.sftpMode = .always
        value.terminalMinimumSeconds = 7
        try source.store.saveNotificationPreferences(value)
        let key = SettingsRecordKey(kind: .notifications, id: "default")
        let envelope = try #require(try source.store.journal.envelope(for: key))
        let record = try SettingsSyncCoordinator.makeRecord(
            .init(envelope: envelope),
            recordID: .init(
                recordName: key.recordName,
                zoneID: .init(zoneName: SettingsSyncCoordinator.zoneName)))
        #expect(record.recordType == "NotificationPreferencesItem")
        #expect(record.recordType != SettingsSyncCoordinator.recordType)
        var callbacks = 0
        destination.store.didRecordChanges = { _ in callbacks += 1 }
        let result = try destination.store.applyRemote([SettingsSyncCoordinator.envelope(from: record)])
        #expect(result.snapshot.notifications == value)
        #expect(try destination.store.loadNotificationPreferences() == value)
        #expect(callbacks == 0)
        #expect(!result.needsUpload.contains(key))
        let older = SettingsEnvelope(key: key, version: .baseline(writerID: UUID()), payload: .notifications(.init()))
        _ = try destination.store.applyRemote([older])
        #expect(try destination.store.loadNotificationPreferences() == value)
        let deletion = SettingsEnvelope(
            key: key,
            version: .next(after: envelope.version, writerID: UUID()), isDeleted: true)
        _ = try destination.store.applyRemote([deletion])
        #expect(try destination.store.loadNotificationPreferences() == NotificationPreferences())
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        #expect(
            Set(encoded?.keys.map { $0 } ?? []) == [
                "isEnabled", "assistantMode", "terminalMode", "sftpMode", "terminalDelivery", "terminalMinimumSeconds",
            ])
    }

    @Test func invalidRemoteDurationIsRejectedAndV41ContainsTheNewEntity() throws {
        var invalid = NotificationPreferences()
        invalid.terminalMinimumSeconds = -1
        let payload = SettingsRecordPayload.notifications(invalid)
        let envelope = SettingsEnvelope(
            key: payload.key, version: .next(after: nil, writerID: UUID()), payload: payload)
        #expect(!envelope.isValid)
        #expect(TermindMigrationPlan.schemas.last?.versionIdentifier == TermindSchemaV42.versionIdentifier)
        #expect(TermindSchemaV41.models.contains { $0 == PersistentNotificationPreferences.self })
        #expect(!TermindSchemaV40.models.contains { $0 == PersistentNotificationPreferences.self })
    }

    @Test func version40StoreUpgradesAndNotificationPreferencesSurviveReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        try writeLegacyStore(url)
        var saved = NotificationPreferences()
        saved.isEnabled = true
        saved.terminalMinimumSeconds = 12
        try saveToUpgradedStore(url, value: saved)
        let reopened = try TermindPersistence.makeContainer(url: url)
        let rows = try reopened.mainContext.fetch(FetchDescriptor<PersistentNotificationPreferences>())
        #expect(try rows.first?.load() == saved)
        let old = try reopened.mainContext.fetch(FetchDescriptor<PersistentWorkspacePreferences>())
        #expect(try old.first?.load().automaticallyRenamesWorkspaces == false)
    }

    private func writeLegacyStore(_ url: URL) throws {
        let schema = Schema(versionedSchema: TermindSchemaV40.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
            ])
        container.mainContext.insert(try PersistentWorkspacePreferences(.init(automaticallyRenamesWorkspaces: false)))
        try container.mainContext.save()
    }

    private func saveToUpgradedStore(_ url: URL, value: NotificationPreferences) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        container.mainContext.insert(try PersistentNotificationPreferences(value))
        try container.mainContext.save()
    }
}

@MainActor private final class NotificationStore: NotificationPreferencesPersisting {
    var value = NotificationPreferences()
    var fails = false
    func loadNotificationPreferences() throws -> NotificationPreferences {
        if fails { throw CocoaError(.fileReadUnknown) }
        return value
    }
    func saveNotificationPreferences(_ value: NotificationPreferences) throws {
        if fails { throw CocoaError(.fileWriteUnknown) }
        self.value = value
    }
}

@MainActor private final class InitialAuthorizationService: NotificationSending {
    var requests: [Bool] = []
    var holdAuthorization = false
    private var pending: CheckedContinuation<Void, Never>?
    private let arrivals = AsyncStream<Void>.makeStream()

    func authorization(request: Bool) async -> NotificationAuthorization {
        requests.append(request)
        if holdAuthorization {
            await withCheckedContinuation {
                pending = $0
                arrivals.continuation.yield(())
            }
        }
        return .notDetermined
    }
    func nextRequest() async {
        var iterator = arrivals.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func finishRequest() {
        pending?.resume()
        pending = nil
    }
    func send(_ notification: AppNotification, ifCurrent: @escaping @MainActor () -> Bool) async {}
    func remove(_ identifiers: [String]) {}
}

@MainActor private struct NotificationFixture {
    let domain = "NotificationPreferencesTests.\(UUID())"
    let defaults: UserDefaults
    let container: ModelContainer
    let store: SettingsSyncPersistence
    init() throws {
        defaults = try #require(UserDefaults(suiteName: domain))
        container = try TermindPersistence.makeContainer(inMemory: true)
        store = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
    }
    func cleanUp() { defaults.removePersistentDomain(forName: domain) }
}
