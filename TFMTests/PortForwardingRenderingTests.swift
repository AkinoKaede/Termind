import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite(.serialized) @MainActor
struct PortForwardingRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func cardsAndJourneyKeepTheirStateAcrossWindowSizes(_ language: String) async throws {
        let host = Host(name: "Production", host: "server.example.invalid")
        let rules = [
            PortForwardingRule(hostID: host.id, label: "Database", colorTag: .teal),
            PortForwardingRule(hostID: host.id, kind: .remote, bindPort: 9090, label: "Preview", colorTag: .orange),
            PortForwardingRule(hostID: host.id, kind: .dynamic, bindPort: 1080, label: "SOCKS5"),
            PortForwardingRule(hostID: host.id, bindPort: 15432),
        ]
        let library = HostLibraryModel(hosts: [host], portForwardings: rules)
        let app = AppModel(hosts: library)
        let navigation = WindowModel()
        navigation.openPage(.portForwarding)
        let controller = NSHostingController(
            rootView: VaultWorkspaceView().environment(app).environment(navigation)
                .environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 740),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 960, height: 740))
        controller.view.frame = NSRect(x: 0, y: 0, width: 960, height: 740)
        window.makeKeyAndOrderFront(nil)
        defer {
            app.shutdownForTermination()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutSubtreeIfNeeded()
        try capture(controller.view, name: "macos-forwarding-cards-\(language)")
        let marquee = try #require(
            descendants(in: controller.view).first { String(describing: type(of: $0)) == "MarqueeInputView" })
        marquee.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 2, y: 2), in: marquee))
        marquee.mouseDragged(
            with: try mouseEvent(
                .leftMouseDragged, at: CGPoint(x: marquee.bounds.maxX - 2, y: marquee.bounds.maxY - 2), in: marquee))
        marquee.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 2, y: 2), in: marquee))
        #expect(Set(navigation.vaultSelection(for: .portForwarding).compactMap(\.forwardingID)) == Set(rules.map(\.id)))
        try await Task.sleep(for: .milliseconds(100))
        try capture(controller.view, name: "macos-forwarding-selected-\(language)")
        marquee.mouseDown(with: try mouseEvent(.leftMouseDown, at: CGPoint(x: 2, y: 2), in: marquee))
        marquee.mouseUp(with: try mouseEvent(.leftMouseUp, at: CGPoint(x: 2, y: 2), in: marquee))
        #expect(navigation.vaultSelection(for: .portForwarding).isEmpty)
        navigation.openVaultWork(.forwardingEditor(rules[0].id), on: .portForwarding)
        try await Task.sleep(for: .milliseconds(300))
        try capture(controller.view, name: "macos-forwarding-editor-\(language)")
        navigation.closeVaultWork()
        app.forwarding.start(rules[0].id)
        for _ in 0..<400 where app.forwarding.connection(for: rules[0].id)?.authenticationPrompt == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let context = try #require(app.forwarding.connection(for: rules[0].id))
        let prompt = try #require(context.authenticationPrompt)
        navigation.openVaultWork(.forwardingEditor(rules[0].id), on: .portForwarding)
        for width in [420.0, 960.0] {
            window.setContentSize(NSSize(width: width, height: 740))
            controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 740)
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutSubtreeIfNeeded()
            #expect(context.authenticationPrompt?.id == prompt.id)
            #expect(window.attachedSheet == nil)
            #expect(app.externalAuthentication.pending.isEmpty)
            try capture(controller.view, name: "macos-forwarding-journey-\(language)-\(Int(width))")
        }
        navigation.closeVaultWork()
        navigation.openPage(.snippets)
        #expect(context.authenticationPrompt?.id == prompt.id)
        navigation.openVaultWork(.forwardingEditor(rules[0].id), on: .portForwarding)
        #expect(app.forwarding.connection(for: rules[0].id) === context)
        app.forwarding.stop(rules[0].id)
        #expect(context.authenticationPrompt == nil)
        #expect(app.forwarding.state(for: rules[0].id) == .stopped)
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: view.window?.windowNumber ?? 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func capture(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "\(name).png")
        let directory = FileManager.default.temporaryDirectory.appending(path: "termind-forwarding-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: "\(name).png"))
    }
}
