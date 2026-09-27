import Foundation
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@Suite @MainActor
struct TerminalCommandMonitorTests {
    private let available = SSHShellIntegrationEvent.available(shell: "zsh", systemInfo: nil, homeDirectory: nil)

    @Test func shortBackgroundCompletionsCountUnreadEvenBelowTheNotificationThreshold() {
        let monitor = TerminalCommandMonitor()
        var alerts = 0
        monitor.alert = { _, _ in alerts += 1 }
        monitor.beginConnection()
        monitor.receiveOSC133(exitCode: 1, durationNanos: 1)
        #expect(monitor.hasUnreadCompletion)
        #expect(alerts == 0)
        monitor.markRead()
        #expect(!monitor.hasUnreadCompletion)
        monitor.receiveOSC133(exitCode: nil, durationNanos: 0)
        #expect(monitor.hasUnreadCompletion)
        monitor.receiveOSC133(exitCode: 0, durationNanos: 0)
        #expect(monitor.unreadCompletionCount == 2)
    }

    @Test(arguments: NotificationPreferences.Mode.allCases)
    func modeAndThresholdUseFocusAtCompletion(_ mode: NotificationPreferences.Mode) {
        let monitor = TerminalCommandMonitor()
        var settings = NotificationPreferences()
        settings.isEnabled = true
        settings.terminalMode = mode
        var focused = false
        var completions: [TerminalCommandCompletion] = []
        monitor.preferences = { settings }
        monitor.isWorkspaceFocused = { focused }
        monitor.alert = { completion, _ in completions.append(completion) }
        monitor.beginConnection()
        monitor.receiveOSC133(exitCode: 0, durationNanos: 4_999_999_999)
        #expect(completions.isEmpty)
        monitor.receiveOSC133(exitCode: 0, durationNanos: 5_000_000_000)
        #expect(completions.count == (mode == .never ? 0 : 1))
        focused = true
        monitor.receiveOSC133(exitCode: nil, durationNanos: 6_000_000_000)
        #expect(!monitor.hasUnreadCompletion)
        #expect(completions.count == (mode == .always ? 2 : mode == .unfocused ? 1 : 0))
    }

    @Test func privateIntegrationWinsAndDuplicateFinishesAreIgnoredWithoutHistory() {
        var clock: TimeInterval = 100
        let monitor = TerminalCommandMonitor(now: { clock })
        var settings = NotificationPreferences()
        settings.isEnabled = true
        settings.terminalMode = .always
        monitor.preferences = { settings }
        var completions: [TerminalCommandCompletion] = []
        monitor.alert = { event, _ in completions.append(event) }
        monitor.beginConnection()
        monitor.receiveShellEvent(available)
        monitor.receiveShellEvent(.commandStarted("sleep 9"))
        monitor.receiveOSC133(exitCode: 0, durationNanos: 9_000_000_000)
        clock = 109
        monitor.receiveShellEvent(.commandFinished(2, duration: nil))
        monitor.receiveShellEvent(.commandFinished(2, duration: nil))
        #expect(completions == [.init(command: "sleep 9", exitCode: 2, duration: 9)])
        monitor.receiveShellEvent(.commandStarted("sleep 7"))
        clock = 120
        monitor.receiveShellEvent(.commandFinished(0, duration: 7))
        #expect(completions.last?.duration == 7)
    }

    @Test func disconnectDiscardsActiveCommandAndReconnectReselectsEventSource() {
        let monitor = TerminalCommandMonitor()
        monitor.beginConnection()
        monitor.receiveShellEvent(available)
        monitor.receiveShellEvent(.commandStarted("old command"))
        monitor.endConnection()
        monitor.receiveShellEvent(.commandFinished(0, duration: 20))
        monitor.receiveOSC133(exitCode: 0, durationNanos: 20_000_000_000)
        #expect(!monitor.hasUnreadCompletion)
        monitor.beginConnection()
        monitor.receiveShellEvent(.commandFinished(0, duration: 20))
        #expect(!monitor.hasUnreadCompletion)
        monitor.receiveOSC133(exitCode: 0, durationNanos: 1)
        #expect(monitor.hasUnreadCompletion)
    }

    @Test(arguments: NotificationPreferences.TerminalDelivery.allCases)
    func terminalDeliveryIsExclusive(_ delivery: NotificationPreferences.TerminalDelivery) {
        let monitor = TerminalCommandMonitor()
        var settings = NotificationPreferences()
        settings.isEnabled = true
        settings.terminalMode = .always
        settings.terminalMinimumSeconds = 0
        settings.terminalDelivery = delivery
        monitor.preferences = { settings }
        var actions: [NotificationPreferences.TerminalDelivery] = []
        monitor.alert = { _, value in actions.append(value.terminalDelivery) }
        monitor.beginConnection()
        monitor.receiveOSC133(exitCode: 0, durationNanos: 0)
        #expect(actions == [delivery])
        settings.isEnabled = false
        monitor.receiveOSC133(exitCode: 0, durationNanos: 10_000_000_000)
        #expect(actions == [delivery])
        #expect(monitor.hasUnreadCompletion)
    }

    @Test func commandPreviewRemovesControlsAndBoundsUnicodeText() {
        let completion = TerminalCommandCompletion(command: "echo\n\thello\u{1b}\u{0} world", exitCode: 0, duration: 1)
        #expect(completion.commandPreview == "echo hello world")
        let long = TerminalCommandCompletion(command: String(repeating: "字", count: 170), exitCode: nil, duration: 0)
        #expect(long.commandPreview?.count == 160)
        #expect(long.commandPreview?.last == "…")
        #expect(TerminalCommandCompletion(exitCode: nil, duration: 0).commandPreview == nil)
    }

}
