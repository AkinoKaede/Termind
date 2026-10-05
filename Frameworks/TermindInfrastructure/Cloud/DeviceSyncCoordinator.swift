import CloudKit
import Foundation
import TermindApplication
import TermindDomain
import TermindPersistence

/// Independently synchronizes the device directory under the master iCloud selection.
@MainActor
public final class DeviceSyncCoordinator {
    // Preserve the deployed zone so fresh installations can read previously uploaded records.
    public nonisolated static let zoneName = HistoryRecordSyncCoordinator.zoneName
    public nonisolated static let subscriptionID = "termind-device-v1-changes"

    let core: HistoryRecordSyncCoordinator
    public var status: VaultSyncStatus { core.status }
    public var didApplyRemote: ((Set<HistoryRecordKey>) -> Void)? {
        get { core.didApplyRemote }
        set { core.didApplyRemote = newValue }
    }

    public convenience init(
        persistence: HistorySyncPersistence,
        container: CKContainer = CKContainer(identifier: CloudSyncContainer.identifier),
        defaults: UserDefaults = .standard,
        environmentIdentifier: String = CloudSyncContainer.environmentIdentifier
    ) {
        self.init(
            persistence: persistence, defaults: defaults, environmentIdentifier: environmentIdentifier,
            makeTransport: {
                .live(container: container, zoneID: $0, subscriptionID: Self.subscriptionID, delegate: $1)
            })
    }

    init(
        persistence: HistorySyncPersistence, defaults: UserDefaults, environmentIdentifier: String,
        makeTransport: @escaping (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    ) {
        core = HistoryRecordSyncCoordinator(
            persistence: persistence, kind: .device, defaults: defaults,
            environmentIdentifier: environmentIdentifier, makeTransport: makeTransport)
    }

    public func configureLogging(_ logging: any ApplicationLogManaging) { core.configureLogging(logging) }
    public func start() { core.start() }
    public func pause() { core.pause() }
    public func retry() { core.retry() }
    public func confirmAccountSwitchMerge() { core.confirmAccountSwitchMerge() }
    public func noteLocalChanges(_ mutations: HistoryMutationSet) { core.noteLocalChanges(mutations) }
}
