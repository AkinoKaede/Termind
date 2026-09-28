import SwiftUI
import TermindApplication
import TermindPresentation
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
    @Test func exportUsesTheNativeHostPickerAcrossSubmissionStates() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for language in ["en", "zh-Hans"] {
            let fixture = KeyExportFixture()
            let recorder = KeyExportRecorder(failingHost: fixture.alpha.id, blocks: true)
            let model = fixture.model(recorder)
            let presentation = KeyExportRenderingPresentation()
            let previous = scene.keyWindow
            let window = UIWindow(windowScene: scene)
            let controller = UIHostingController(
                rootView: KeyExportRenderingHost(fixture: fixture, model: model, presentation: presentation)
                    .environment(\.locale, Locale(identifier: language)))
            window.rootViewController = controller
            window.windowLevel = .alert + 1
            window.makeKeyAndVisible()
            defer {
                presentation.isPresented = false
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            try await Task.sleep(for: .milliseconds(700))
            presentation.isPresented = true
            try await capture(window, language: language, state: "selecting")
            let sheet = try #require(controller.presentedViewController)
            let navigation = try #require(descendant(UINavigationController.self, in: sheet))
            let confirm = try #require(confirmation(in: navigation))
            #expect(!confirm.isEnabled)
            if UIDevice.current.userInterfaceIdiom == .pad {
                let frame = try #require(sheet.presentationController?.frameOfPresentedViewInContainerView)
                #expect(abs(frame.midX - window.bounds.midX) < 2)
                #expect(abs(frame.midY - window.bounds.midY) < 2)
            }
            let export = Task { await model.export(to: [fixture.alpha.id]) }
            await recorder.waitUntilStarted()
            try await capture(window, language: language, state: "running")
            #expect(try !#require(confirmation(in: navigation)).isEnabled)
            await recorder.resume()
            await export.value
            #expect(model.isFinished)
            try await capture(window, language: language, state: "failed")
            #expect(try #require(confirmation(in: navigation)).isEnabled)
        }
    }

    private func descendant<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let result = controller as? T { return result }
        return controller.children.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private func confirmation(in navigation: UINavigationController) -> UIBarButtonItem? {
        guard let item = navigation.topViewController?.navigationItem else { return nil }
        let buttons = item.trailingItemGroups.flatMap(\.barButtonItems) + (item.rightBarButtonItems ?? [])
        return buttons.first { $0.accessibilityIdentifier == "host-picker.confirm" } ?? buttons.first
    }

    private func capture(_ window: UIWindow, language: String, state: String) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        #expect(data.count > 10000)
        let directory = FileManager.default.temporaryDirectory.appending(path: "key-export-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let output = directory.appending(path: "\(device)-\(language)-\(state).png")
        try data.write(to: output)
        print("Key export snapshot: \(output.path)")
    }
}

@MainActor @Observable
private final class KeyExportRenderingPresentation {
    var isPresented = false
}

private struct KeyExportRenderingHost: View {
    let fixture: KeyExportFixture
    let model: KeyExportModel
    @Bindable var presentation: KeyExportRenderingPresentation
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Color.clear
            .sheet(isPresented: $presentation.isPresented) {
                MobileKeyExportSheet(library: fixture.library, credentials: fixture.credentials, model: model)
            }
            // Match the presenting-window environment established by MobileRootView.
            .environment(\.mobileLayout, MobileLayout(sizeClass: sizeClass))
    }
}
