import AgentKit
import AppKit
import SwiftUI
import TermindApplication
import TermindPersistence
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct MemorySettingsRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func memorySettingsRenderWithCapacity(_ language: String, dark: Bool) async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "memory-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let memory = MemoryModel(storage: GRDBMemoryStore(directory: url))
        await memory.setEnabled(true)
        if dark {
            await memory.edit(.memory, text: String(repeating: "记", count: AgentMemoryTarget.memory.characterLimit / 2))
        }
        await memory.edit(
            .user, text: String(repeating: "忆", count: AgentMemoryTarget.user.characterLimit / (dark ? 2 : 1)))
        #expect(memory.error == nil)
        let view = Form {
            MemorySettingsSection(memory: memory, ai: AIConfigurationModel())
        }.formStyle(.grouped)
        try await capture(
            view, language: language, dark: dark, size: CGSize(width: dark ? 420 : 620, height: 560),
            name: "termind-memory")
        await memory.destroy()
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func skillEditorRendersCompactActions(_ language: String, dark: Bool) async throws {
        let skill = AgentSkill(
            name: "release-checklist", title: "Release Checklist", summary: "Review a release before publishing.",
            body: "# Release Checklist\n\nRun the tests and review the release notes.",
            package: dark ? AgentSkillPackage(files: ["references/notes.md": Data("Release notes".utf8)]) : nil)
        let app = AppModel(hosts: HostLibraryModel(), skills: SkillLibraryModel(skills: [skill]))
        defer { app.shutdownForTermination() }
        try await capture(
            SkillEditorPage(skillID: skill.id, deleted: {}).environment(app),
            language: language, dark: dark, size: CGSize(width: dark ? 420 : 620, height: 960), name: "termind-skill")
    }

    private func capture(
        _ content: some View, language: String, dark: Bool, size: CGSize, name: String
    ) async throws {
        let view = content.frame(width: size.width, height: size.height)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, dark ? .dark : .light)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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
        Attachment.record(bytes, named: "\(name)-\(language)-\(dark ? "dark" : "light").png")
        #expect(bytes.count > 20_000)
    }
}
