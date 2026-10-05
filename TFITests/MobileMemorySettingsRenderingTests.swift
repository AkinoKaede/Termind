import SwiftUI
import TermindApplication
import TermindPersistence
import TermindPresentation
import Testing
import UIKit

@Suite(.requiresKeyWindow, .serialized) @MainActor
struct MobileMemorySettingsRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func memorySettingsHaveNativeMobileLayout(_ language: String, enabled: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "memory-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = MemoryModel(storage: GRDBMemoryStore(directory: directory))
        if enabled {
            await model.setEnabled(true)
            await model.edit(.user, text: "Prefers concise answers and explicit verification.")
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let view = NavigationStack(path: .constant(["memory"])) {
            Text("AI").navigationTitle("AI")
                .navigationDestination(for: String.self) { _ in
                    MemorySettingsSection(memory: model, ai: AIConfigurationModel(), layout: .page)
                        .navigationTitle("Hermes Memory")
                }
        }.environment(\.locale, Locale(identifier: language))
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        let navigation = try #require(navigationController(in: controller))
        #expect(navigation.viewControllers.count == 2)
        let navigationItem = try #require(navigation.topViewController?.navigationItem)
        let actions = navigationItem.rightBarButtonItems ?? navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
        #expect(actions.count == 1)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        Attachment.record(data, named: "mobile-memory-\(language)-\(enabled ? "enabled" : "disabled").png")
        await model.destroy()
    }

    private func navigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        for child in controller.children {
            if let navigation = navigationController(in: child) { return navigation }
        }
        return nil
    }
}
