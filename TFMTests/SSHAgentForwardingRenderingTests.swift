import AppKit
import SwiftUI
import TermindDomain
import TermindPresentation
import Testing

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct SSHAgentForwardingRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func sessionSettingsRenderAtNarrowWidth(_ language: String) async throws {
        let controller = NSHostingController(
            rootView: Form {
                HostSessionSection(
                    charset: .constant(.utf8), sftpInitialPath: .constant(""),
                    agentForwardingEnabled: .constant(true))
            }.formStyle(.grouped)
                .environment(\.locale, Locale(identifier: language))
                .frame(width: 400, height: 560))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(400))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 5000)
        Attachment.record(data, named: "agent-forwarding-mac-\(language).png")
        try data.write(
            to: FileManager.default.temporaryDirectory.appending(path: "agent-forwarding-mac-\(language).png"))
    }
}
