import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct HostIntegrationRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [320.0, 360.0, 480.0])
    func hostEditorShowsIntegrationBelowGroupingAtNarrowWidth(language: String, width: CGFloat) async throws {
        let host = TermindDomain.Host(name: "Production", host: "server.invalid")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let navigation = WindowModel()
        let controller = NSHostingController(
            rootView: HostEditorView(hostID: host.id).environment(app).environment(navigation)
                .environment(\.locale, Locale(identifier: language))
                .frame(width: width, height: 1400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 1400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 1400)
        window.orderFront(nil)
        defer {
            app.shutdownForTermination()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutSubtreeIfNeeded()
        let defaultLabel = AppLocalization.string("Default", locale: Locale(identifier: language))
        #expect(descendants(controller.view).compactMap { $0 as? NSSegmentedControl }.isEmpty)
        let control = try #require(
            descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first { $0.title == defaultLabel })
        let frame = control.convert(control.bounds, to: controller.view)
        #expect(frame.minX >= 16 && frame.maxX <= width - 16)
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "host-integration-mac-\(language)-\(Int(width)).png")
        try data.write(
            to: FileManager.default.temporaryDirectory.appending(
                path: "host-integration-mac-\(language)-\(Int(width)).png"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
