import AppKit
import SwiftUI
import TermindApplication
import TermindPersistence
import TermindPresentation
import Testing

@Suite(.serialized) @MainActor
struct MemorySettingsRenderingTests {
    @Test(arguments: ["en", "zh-Hans"])
    func memorySettingsRenderWithDestroy(_ language: String) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "memory-render-\(UUID())")
        let memory = MemoryModel(storage: GRDBMemoryStore(directory: url))
        await memory.setEnabled(true)
        await memory.edit(.user, text: "Prefers concise answers and explicit verification.")
        let view = Form {
            MemorySettingsSection(memory: memory, ai: AIConfigurationModel())
        }.formStyle(.grouped).frame(width: 620, height: 720)
            .environment(\.locale, Locale(identifier: language))
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutSubtreeIfNeeded()
        let representation = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: representation)
        let bytes = try #require(representation.representation(using: .png, properties: [:]))
        Attachment.record(bytes, named: "termind-memory-\(language).png")
        #expect(bytes.count > 20_000)
        await memory.destroy()
    }
}
