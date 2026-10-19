import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct WelcomeQuickConnectRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func welcomePreviewsCommandsAndRejectsRemoteCommands(_ language: String) async throws {
        let library = HostLibraryModel()
        let app = AppModel(hosts: library)
        let navigation = WindowModel()
        let controller = NSHostingController(
            rootView: WelcomeView().environment(app).environment(navigation)
                .environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 540),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(CGSize(width: 680, height: 540))
        controller.view.frame = CGRect(x: 0, y: 0, width: 680, height: 540)
        defer {
            app.shutdownForTermination()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(900))
        let field = try #require(descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        // Return on an invalid command must neither clear the field nor open a session.
        field.stringValue = "ssh server.example uptime"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(50))
        let action = try #require(field.action)
        #expect(field.sendAction(action, to: field.target))
        await Task.yield()
        #expect(navigation.workspaces.isEmpty)
        #expect(field.stringValue == "ssh server.example uptime")
        field.stringValue = "ssh -p2222 deploy@server.example"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        try await Task.sleep(for: .milliseconds(50))
        #expect(field.sendAction(action, to: field.target))
        try await Task.sleep(for: .milliseconds(50))
        let session = try #require(navigation.workspaces.first?.focusedPane.sshSession)
        #expect(session.connectionRoute?.hosts.last?.port == 2222)
        #expect(field.stringValue.isEmpty)
        #expect(library.hosts.isEmpty)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

}
