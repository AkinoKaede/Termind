import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@Suite @MainActor
struct SFTPNotificationTests {
    @Test func clearingFinishedHistoryPreservesThePendingBatchSummary() async {
        let fixture = Fixture()
        var removed = Set<UUID>()
        fixture.store.sftpTransfersDidRemove = { [weak coordinator = fixture.coordinator] ids in
            removed.formUnion(ids)
            coordinator?.forgetFinishedTransfers(ids)
        }
        let first = fixture.enqueue()
        let second = fixture.enqueue()
        fixture.store.finishSFTPTransfer(first, state: .completed)
        fixture.store.removeFinishedSFTPTransfer(first)
        #expect(removed == [first])
        fixture.store.finishSFTPTransfer(second, state: .failed("failure"))
        fixture.store.clearFinishedSFTPTransfers()
        #expect(removed == [first, second])
        await settle()
        #expect(fixture.sender.sent.map(\.body) == ["1/1"])
    }

    @Test func stoppingCancelsASuspendedDelivery() async {
        let sender = NotificationDeliveryRecorder()
        let coordinator = SFTPNotificationCoordinator(
            service: sender, preferences: { .init() }, isFocused: { false }, content: { _, _ in ("", "") })
        coordinator.receive(SFTPTransfer(localPath: "local", remotePath: "remote", state: .completed))
        _ = await sender.nextRequest()
        coordinator.stop()
        await sender.finishDelivery()
        #expect(sender.sent.isEmpty)
    }

    @Test func allTransfersFinishBeforeOneSummaryAndPausedWorkIsExcluded() async {
        let fixture = Fixture()
        let first = fixture.enqueue()
        let second = fixture.enqueue()
        let paused = fixture.enqueue()
        fixture.store.setSFTPTransferState(.paused, for: paused)
        fixture.store.finishSFTPTransfer(first, state: .completed)
        await settle()
        #expect(fixture.sender.sent.isEmpty)
        fixture.store.finishSFTPTransfer(second, state: .failed("private reason"))
        await settle()
        #expect(fixture.sender.sent.count == 1)
        #expect(fixture.sender.sent[0].body == "1/1")
        #expect(fixture.sender.sent[0].target == .transfers)
        fixture.store.finishSFTPTransfer(second, state: .failed("duplicate"))
        fixture.store.setSFTPTransferState(.running, for: paused)
        fixture.store.finishSFTPTransfer(paused, state: .completed)
        await settle()
        #expect(fixture.sender.sent.map(\.body) == ["1/1", "1/0"])
    }

    @Test func pausingOrCancellingAloneNeverNotifiesAndHistoryIsNotReplayed() async {
        let fixture = Fixture()
        let id = fixture.enqueue()
        fixture.store.setSFTPTransferState(.paused, for: id)
        fixture.store.finishSFTPTransfer(id, state: .cancelled)
        await settle()
        #expect(fixture.sender.sent.isEmpty)
        let history = SFTPTransfer(localPath: "old", remotePath: "old", state: .completed)
        let coordinator = SFTPNotificationCoordinator(
            service: fixture.sender, initialTransfers: [history], preferences: { fixture.preferences },
            isFocused: { false }, content: { _, _ in ("Transfers", "old") })
        coordinator.receive(history)
        await settle()
        #expect(fixture.sender.sent.isEmpty)
    }

    @Test(arguments: NotificationPreferences.Mode.allCases, [false, true])
    func modeUsesWhetherAnyWindowIsInTheForeground(_ mode: NotificationPreferences.Mode, foreground: Bool) async {
        let fixture = Fixture()
        fixture.preferences.sftpMode = mode
        fixture.foreground = foreground
        fixture.store.finishSFTPTransfer(fixture.enqueue(), state: .failed("failure"))
        await settle()
        #expect(fixture.sender.sent.count == (mode.allows(isFocused: foreground) ? 1 : 0))
        let count = fixture.sender.sent.count
        fixture.preferences.isEnabled = false
        fixture.store.finishSFTPTransfer(fixture.enqueue(), state: .completed)
        await settle()
        #expect(fixture.sender.sent.count == count)
        fixture.preferences.isEnabled = true
        fixture.foreground = false
        await settle()
        #expect(fixture.sender.sent.count == count)
    }

    @Test func transfersTargetRoundTripsWithoutAnEntityID() {
        #expect(NotificationTarget(kind: NotificationTarget.transfers.kind, id: "") == .transfers)
        #expect(NotificationTarget.transfers.id == nil)
        #expect(!SFTPNotificationContent.make(succeeded: 2, failed: 1).body.isEmpty)
    }

    @Test(arguments: [false, true])
    func stoppingOrDisablingNotificationsBeforeDeliverySuppressesTheResult(stop: Bool) async {
        let fixture = Fixture()
        fixture.store.finishSFTPTransfer(fixture.enqueue(), state: .completed)
        if stop { fixture.coordinator.stop() } else { fixture.preferences.isEnabled = false }
        await settle()
        #expect(fixture.sender.sent.isEmpty)
    }

    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    private final class Fixture {
        let sender = Sender()
        let store = HostLibraryModel()
        var preferences = NotificationPreferences()
        var foreground = false
        var coordinator: SFTPNotificationCoordinator!
        init() {
            preferences.sftpMode = .always
            coordinator = SFTPNotificationCoordinator(
                service: sender, preferences: { [weak self] in self?.preferences ?? .init() },
                isFocused: { [weak self] in self?.foreground ?? true }, content: { ("Transfers", "\($0)/\($1)") })
            store.sftpTransferStateDidChange = { [weak coordinator] in coordinator?.receive($0) }
        }
        func enqueue() -> UUID {
            let transfer = SFTPTransfer(localPath: "local", remotePath: "remote")
            store.enqueueSFTPTransfer(transfer)
            return transfer.id
        }
    }

    private final class Sender: NotificationSending {
        var sent: [AppNotification] = []
        func authorization(request: Bool) async -> NotificationAuthorization { .allowed }
        func send(_ notification: AppNotification, ifCurrent: @escaping @MainActor () -> Bool) async {
            if ifCurrent() { sent.append(notification) }
        }
        func remove(_ identifiers: [String]) {}
    }
}
