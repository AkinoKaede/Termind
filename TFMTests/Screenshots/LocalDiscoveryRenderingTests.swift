import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct LocalDiscoveryRenderingTests {
    @Test(arguments: ["en", "zh-Hans"])
    func discoveredHostsUseTheNativeDetail(language: String) async throws {
        let service = PreviewDiscovery()
        let model = LocalDiscoveryModel(service: service)
        let controller = NSHostingController(
            rootView: HostLocalDiscoveryView(model: model, back: {}, select: { _ in })
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, .light)
                .frame(width: 720, height: 520))
        controller.sizingOptions = []
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 720, height: 520),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.title = "Termind"
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            model.cancel()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        for _ in 0..<100 {
            if model.phase == .finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.phase == .finished)
        #expect(model.hosts.contains { $0.source == .bonjour })
        #expect(model.hosts.contains { $0.source == .probe })
        #expect(service.scanCount == 1)
        model.scan()
        for _ in 0..<100 {
            if model.phase == .finished { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(model.phase == .finished)
        #expect(service.scanCount == 2)
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        Attachment.record(
            try #require(bitmap.representation(using: .png, properties: [:])),
            named: "macos-\(language)-discovery.png")
        // An external runner can capture compositor output, including native glass, during this interval.
        FileHandle.standardOutput.write(
            Data("TERMIND_DISCOVERY_WINDOW|\(window.windowNumber)|macos-\(language)-discovery\n".utf8))
        try await Task.sleep(for: .seconds(3))
    }
}

@MainActor
private final class PreviewDiscovery: LocalHostDiscovering {
    let connectionProtocol = LocalDiscoveryProtocol.ssh
    private(set) var scanCount = 0

    func discover() async throws -> [DiscoveredLocalHost] {
        scanCount += 1
        return [
            .init(name: "Mac mini", address: "mac-mini.local", port: 22, source: .bonjour),
            .init(name: "192.168.1.24", address: "192.168.1.24", port: 22, source: .probe),
            .init(name: "Raspberry Pi", address: "raspberrypi.local", port: 22, source: .bonjour),
        ]
    }
}
