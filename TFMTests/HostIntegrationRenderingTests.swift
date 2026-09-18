import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct HostIntegrationRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func hostEditorShowsIntegrationBelowGroupingAtNarrowWidth(language: String) async throws {
        let host = TermindDomain.Host(name: "Production", host: "server.invalid")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let navigation = WindowModel()
        let controller = NSHostingController(
            rootView: HostEditorView(hostID: host.id).environment(app).environment(navigation)
                .environment(\.locale, Locale(identifier: language))
                .frame(width: 360, height: 1400))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 1400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 360, height: 1400)
        window.orderFront(nil)
        defer {
            app.shutdownForTermination()
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutSubtreeIfNeeded()
        let control = try #require(descendants(controller.view).compactMap { $0 as? NSSegmentedControl }.first)
        #expect(control.segmentCount == 3)
        #expect(control.selectedSegment == 1)
        let labels = (0..<3).map { control.label(forSegment: $0) ?? "" }
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(labels[1] == AppLocalization.string("Follow Global Settings", locale: Locale(identifier: language)))
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "host-integration-mac-\(language).png")
        try data.write(
            to: FileManager.default.temporaryDirectory.appending(path: "host-integration-mac-\(language).png"))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
