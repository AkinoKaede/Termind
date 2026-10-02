import AppKit
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct DiagnosisConsentRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [360.0, 560.0])
    func introductoryPageRendersWithoutChangingConsent(language: String, width: Double) async throws {
        let domain = "DiagnosisRendering.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let controller = DiagnosisController(defaults: defaults)
        let content = DiagnosisConsentView(controller: controller)
            .environment(\.locale, Locale(identifier: language))
            .frame(width: width, height: 680)
            .background(.background)
        let host = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 680),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(controller.needsConsent)
        #expect(defaults.object(forKey: SettingsKey.diagnosisConsent) == nil)
        Attachment.record(png, named: "diagnosis-\(language)-\(Int(width)).png")
    }
}
