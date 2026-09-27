import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct CommandNotificationRenderingTests {
    @Test(arguments: ["en", "zh-Hans"], [false, true])
    func notificationsAndWorkspaceDot(_ language: String, dark: Bool) async throws {
        let host = Host(name: "Build Server", host: "build.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let windowModel = WindowModel()
        app.registerWindow(windowModel)
        let pane = Pane.sshSession(host: host)
        windowModel.open(Workspace(pane: pane), select: false)
        pane.commandMonitor?.beginConnection()
        pane.commandMonitor?.receiveOSC133(exitCode: 0, durationNanos: 1)
        var settings = CommandNotificationPreferences()
        settings.mode = .unfocused
        app.terminalSettings.set(settings, for: \.commandNotifications)
        let view = HStack(spacing: 0) {
            WorkspaceNavigatorView().frame(width: 230)
            Form {
                TerminalCommandNotificationFields(
                    model: app.terminalSettings,
                    service: app.commandNotifications, openSettings: {})
            }.formStyle(.grouped).frame(width: 520)
        }
        .environment(app).environment(windowModel)
        .environment(\.locale, Locale(identifier: language))
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: 750, height: 560)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 560),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            app.shutdownForTermination()
        }
        try await Task.sleep(for: .milliseconds(350))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "command-notifications-mac-\(language)-\(dark).png")
    }
}
