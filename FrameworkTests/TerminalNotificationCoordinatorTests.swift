// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct TerminalNotificationCoordinatorTests {
    enum Change: CaseIterable { case disabled, bell, closed, focused, stopped }

    @Test(arguments: Change.allCases)
    func deliveryRechecksLiveStateAfterSuspension(_ change: Change) async {
        let fixture = Fixture()
        fixture.complete()
        _ = await fixture.sender.nextRequest()
        switch change {
        case .disabled: fixture.settings.isEnabled = false
        case .bell: fixture.settings.terminalDelivery = .bell
        case .closed: fixture.exists = false
        case .focused: fixture.focused = true
        case .stopped: fixture.coordinator.stop()
        }
        await fixture.sender.finishDelivery()
        #expect(fixture.sender.sent.isEmpty)
        #expect(fixture.bells == 0)
    }

    @Test func systemDeliveryUsesTheTerminalIdentityAndCurrentTitle() async {
        let fixture = Fixture()
        fixture.complete()
        let request = await fixture.sender.nextRequest()
        #expect(request?.target == .terminal(fixture.id))
        #expect(request?.title == "Build")
        #expect(request?.body == "Completed")
        await fixture.sender.finishDelivery()
        #expect(fixture.sender.sent.count == 1)
        #expect(fixture.bells == 0)
    }

    @Test func bellIsExclusiveAndStoppingPreservesUnreadAccounting() {
        let fixture = Fixture()
        fixture.settings.terminalDelivery = .bell
        fixture.complete()
        #expect(fixture.bells == 1)
        #expect(fixture.sender.startedCount == 0)
        fixture.coordinator.stop()
        fixture.complete()
        #expect(fixture.bells == 1)
        #expect(fixture.monitor.unreadCompletionCount == 2)
    }

    private final class Fixture {
        let id = UUID()
        let monitor = TerminalCommandMonitor()
        let sender = NotificationDeliveryRecorder()
        var settings = NotificationPreferences()
        var exists = true
        var focused = false
        var bells = 0
        lazy var coordinator = TerminalNotificationCoordinator(
            service: sender,
            preferences: { [unowned self] in settings },
            isFocused: { [unowned self] _ in focused },
            title: { [unowned self] _ in exists ? "Build" : nil },
            body: { _ in "Completed" },
            ringBell: { [unowned self] in bells += 1 })

        init() {
            settings.terminalMinimumSeconds = 0
            coordinator.observe(monitor, id: id)
            monitor.beginConnection()
        }
        func complete() { monitor.receiveOSC133(exitCode: 0, durationNanos: 1) }
    }
}
