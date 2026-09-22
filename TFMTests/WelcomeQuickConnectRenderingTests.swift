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
    func welcomeGlassRowsRenderRecentsHostsAndOneOffConnections(_ language: String) async throws {
        let localDeviceID = UUID()
        let ubuntuDistribution = try #require(DetectedDistribution(id: "ubuntu"))
        let unknownDistribution = try #require(DetectedDistribution(id: "termind-test-os"))
        let ubuntu = Host(
            name: "Ubuntu Server", host: "ubuntu.example", colorTag: .orange,
            detectedDistribution: ubuntuDistribution
        )
        let unknown = Host(
            name: "Unknown Server", host: "unknown.example",
            detectedDistribution: unknownDistribution
        )
        let disconnected = Host(
            name: "Disconnected Server", host: "disconnected.example"
        )
        let template = WorkspaceTemplate(
            name: "Operations",
            layout: .split(
                axis: .horizontal,
                fraction: 0.5,
                first: .pane(.ssh(hostID: ubuntu.id)),
                second: .pane(.ssh(hostID: unknown.id))
            )
        )
        let library = HostLibraryModel(
            hosts: [ubuntu, unknown, disconnected], workspaceTemplates: [template]
        )
        library.setStatus(.connected, for: ubuntu.id)
        library.setStatus(.connecting, for: unknown.id)
        let history = ConnectionHistoryModel(
            entries: [
                ConnectionHistoryEntry(
                    hostID: ubuntu.id, kind: .ssh,
                    connectedAt: Date(timeIntervalSince1970: 20),
                    sourceDeviceID: localDeviceID
                ),
                ConnectionHistoryEntry(
                    hostID: unknown.id, kind: .ssh,
                    connectedAt: Date(timeIntervalSince1970: 10),
                    sourceDeviceID: localDeviceID
                ),
                ConnectionHistoryEntry(
                    hostID: disconnected.id, kind: .ssh,
                    connectedAt: Date(timeIntervalSince1970: 5),
                    sourceDeviceID: localDeviceID
                ),
            ],
            sourceDeviceID: localDeviceID
        )
        let app = AppModel(hosts: library, connectionHistory: history)
        let navigation = WindowModel()
        let controller = NSHostingController(
            rootView: WelcomeView().environment(app).environment(navigation)
                .environment(\.locale, Locale(identifier: language))
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(CGSize(width: 680, height: 620))
        controller.view.frame = CGRect(x: 0, y: 0, width: 680, height: 620)
        defer {
            app.shutdownForTermination()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }

        #expect(LinuxDistributionIconCatalog.entry(for: ubuntuDistribution) != nil)
        #expect(LinuxDistributionIconCatalog.entry(for: unknownDistribution) == nil)

        try await Task.sleep(for: .milliseconds(150))
        let field = try #require(
            descendants(controller.view).compactMap { $0 as? NSTextField }.first { $0.isEditable }
        )
        for (appearanceName, appearance) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua),
        ] {
            window.appearance = NSAppearance(named: appearance)

            try await update(field, with: "", in: controller.view)
            try capture(
                controller.view,
                name: "welcome-glass-recents-\(appearanceName)-\(language)"
            )

            try await update(field, with: "Server", in: controller.view)
            try capture(
                controller.view,
                name: "welcome-glass-hosts-\(appearanceName)-\(language)"
            )

            try await update(field, with: "ssh deploy@one-off.example", in: controller.view)
            try capture(
                controller.view,
                name: "welcome-glass-connect-once-\(appearanceName)-\(language)"
            )

            window.setContentSize(CGSize(width: 360, height: 620))
            controller.view.frame = CGRect(x: 0, y: 0, width: 360, height: 620)
            try await Task.sleep(for: .milliseconds(50))
            controller.view.layoutSubtreeIfNeeded()
            try capture(
                controller.view,
                name: "welcome-glass-narrow-\(appearanceName)-\(language)"
            )
            window.setContentSize(CGSize(width: 680, height: 620))
            controller.view.frame = CGRect(x: 0, y: 0, width: 680, height: 620)
        }
    }

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

    private func update(_ field: NSTextField, with value: String, in view: NSView) async throws {
        field.stringValue = value
        field.delegate?.controlTextDidChange?(
            Notification(name: NSControl.textDidChangeNotification, object: field)
        )
        try await Task.sleep(for: .milliseconds(50))
        view.layoutSubtreeIfNeeded()
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
