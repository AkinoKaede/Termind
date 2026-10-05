import SwiftUI
import TermindApplication
import Testing
import UIKit

@testable import TermindIOS

@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1",
        "Set TERMIND_MOBILE_UI_TESTS=1 and disable parallel testing for key-window integration tests"),
    .serialized
)
@MainActor
struct MobileKeyExportRenderingTests {
    @Test func exportUsesANativeDetailAndShowsTheKeyPassphraseInTheForm() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for language in ["en", "zh-Hans"] {
            let fixture = try MobileExportFixture(encrypted: true)
            let model = fixture.model()
            model.hostID = fixture.host.id
            let previous = scene.keyWindow
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(
                rootView:
                    NavigationStack {
                        MobileKeyExportDetailView(library: fixture.library, model: model)
                    }.environment(\.locale, Locale(identifier: language)))
            window.rootViewController = controller
            window.windowLevel = .alert + 1
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            try await Task.sleep(for: .milliseconds(800))
            #expect(controller.presentedViewController == nil)
            #expect(model.needsExportPassphrase && !model.canStart && !model.journey.isPresented)
            try capture(window, language: language)
            let passphraseField = try #require(
                descendants(window).compactMap { $0 as? UITextField }.first { $0.isSecureTextEntry })
            #expect(passphraseField.becomeFirstResponder())
            try await Task.sleep(for: .milliseconds(400))
            try capture(window, language: language, state: "keyboard")
            window.endEditing(true)
            model.exportPassphrase = "secret"
            #expect(model.canStart)
            try await Task.sleep(for: .milliseconds(400))
            try capture(window, language: language, state: "ready")
        }
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func capture(_ window: UIWindow, language: String, state: String = "form") throws {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "key-export-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let output = directory.appending(path: "\(device)-\(language)-\(state).png")
        try #require(image.pngData()).write(to: output)
        print("Key export snapshot: \(output.path)")
    }
}
