import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
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
        for (name, query) in [
            ("route", "ssh -J bastion@jump.example:2200 -p 2222 deploy@server.example"),
            ("unsupported", "ssh -i ~/.ssh/id_ed25519 deploy@server.example"),
            ("incomplete", "ssh -p"),
        ] {
            field.stringValue = query
            field.delegate?.controlTextDidChange?(
                Notification(name: NSControl.textDidChangeNotification, object: field))
            try await Task.sleep(for: .milliseconds(150))
            controller.view.layoutSubtreeIfNeeded()
            #expect(field.stringValue == query)
            #expect(navigation.workspaces.isEmpty)
            #expect(library.hosts.isEmpty)
            try capture(controller.view, name: "welcome-ssh-\(name)-\(language)")
            if name == "route" {
                window.setContentSize(CGSize(width: 360, height: 540))
                controller.view.frame = CGRect(x: 0, y: 0, width: 360, height: 540)
                try await Task.sleep(for: .milliseconds(100))
                controller.view.layoutSubtreeIfNeeded()
                try capture(controller.view, name: "welcome-ssh-narrow-\(language)")
                window.setContentSize(CGSize(width: 680, height: 540))
                controller.view.frame = CGRect(x: 0, y: 0, width: 680, height: 540)
            }
        }
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

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TERMIND_RENDER_DIR"] else { return }
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url.appendingPathComponent("\(name).png"))
    }
}
