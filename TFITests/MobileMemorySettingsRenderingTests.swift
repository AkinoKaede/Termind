import SwiftUI
import TermindApplication
import TermindPersistence
import TermindPresentation
import Testing
import UIKit

@Suite(.serialized) @MainActor
struct MobileMemorySettingsRenderingTests {
    @Test(arguments: ["en", "zh-Hans"])
    func memorySettingsHaveNativeMobileLayout(_ language: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "memory-render-\(UUID())")
        let model = MemoryModel(storage: GRDBMemoryStore(directory: directory))
        await model.setEnabled(true)
        await model.edit(.user, text: "Prefers concise answers and explicit verification.")
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let view = NavigationStack {
            Form { MemorySettingsSection(memory: model, ai: AIConfigurationModel()) }
                .navigationTitle("Hermes Memory")
        }.environment(\.locale, Locale(identifier: language))
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        #expect(data.count > 10_000)
        Attachment.record(data, named: "mobile-memory-\(language).png")
        await model.destroy()
    }
}
