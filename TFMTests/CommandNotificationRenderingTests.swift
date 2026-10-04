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
        let conversation = ConversationModel()
        conversation.composer.draft = "Deploy staging"
        conversation.sendDraft()
        windowModel.assistantLibrary.insertAndSelect(conversation)
        let coordinator = AssistantNotificationCoordinator(
            service: app.notifications, preferences: { .init() }, isFocused: { _ in false },
            content: AssistantNotificationContent.make)
        coordinator.observe(conversation)
        conversation.handle(.runFinished(.init(id: UUID(), state: .completed, startedAt: .now)))
        conversation.markNotificationsUnread()
        #expect(app.unreadAssistantNotificationCount == 1)
        let pane = Pane.sshSession(host: host)
        windowModel.open(Workspace(pane: pane), select: false)
        pane.commandMonitor?.beginConnection()
        pane.commandMonitor?.receiveOSC133(exitCode: 0, durationNanos: 1)
        app.notificationSettings.set(true, for: \.isEnabled)
        let view = HStack(spacing: 0) {
            WindowSidebarView().frame(width: 230)
            Form {
                NotificationSettingsFields(
                    model: app.notificationSettings,
                    service: app.notifications, openSettings: {})
            }.formStyle(.grouped).frame(width: 520)
        }
        .environment(app).environment(windowModel)
        .environment(\.locale, Locale(identifier: language))
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: 750, height: 720)
        .background(TermindColor.windowSurface)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 720),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
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

    @Test func transfersNotificationOpensAndReusesTheTransfersWindow() throws {
        let app = AppModel(hosts: HostLibraryModel())
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            app.mainWindows.saveSizeForTermination()
            app.shutdownForTermination()
        }
        app.mainWindows.showTransfers()
        let window = try #require(NSApp.windows.first { !originalWindows.contains(ObjectIdentifier($0)) })
        #expect(window.title == String(localized: AppStrings.SFTP.transfers))
        #expect(window.isVisible)
        #expect(window.contentViewController != nil)
        app.mainWindows.showTransfers()
        #expect(NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.count == 1)
        window.miniaturize(nil)
        app.mainWindows.showTransfers()
        #expect(!window.isMiniaturized)
        window.close()
        #expect(!window.isVisible)
        app.mainWindows.showTransfers()
        #expect(window.isVisible)
        #expect(NSApp.windows.filter { !originalWindows.contains(ObjectIdentifier($0)) }.count == 1)
    }
}
