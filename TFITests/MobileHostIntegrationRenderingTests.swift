import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileHostIntegrationRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func integrationPickerKeepsItsDraftAtPhoneWidth(language: String) async throws {
        let draft = HostIntegrationDraft()
        let controller = UIHostingController(
            rootView: Form {
                Section("Group") { Text("Production") }
                HostIntegrationSection {
                    MobileHostIntegrationPicker(mode: Binding(get: { draft.mode }, set: { draft.mode = $0 }))
                }
            }
            .environment(\.locale, Locale(identifier: language)))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 400)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()
        let picker = try #require(descendants(controller.view).compactMap { $0 as? UISegmentedControl }.first)
        #expect(picker.numberOfSegments == 3)
        #expect(picker.apportionsSegmentWidthsByContent)
        #expect(picker.selectedSegmentIndex == 1)
        #expect(
            picker.titleForSegment(at: 1)
                == AppLocalization.string("Follow Global Settings", locale: Locale(identifier: language)))
        picker.selectedSegmentIndex = 0
        picker.sendActions(for: .valueChanged)
        #expect(draft.mode == .enabled)
        picker.selectedSegmentIndex = 2
        picker.sendActions(for: .valueChanged)
        #expect(draft.mode == .disabled)
        picker.selectedSegmentIndex = 1
        picker.sendActions(for: .valueChanged)
        #expect(draft.mode == .followGlobalSettings)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            #expect(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let data = try #require(image.pngData())
        #expect(data.count > 5_000)
        Attachment.record(data, named: "host-integration-mobile-\(language).png")
        try data.write(
            to: FileManager.default.temporaryDirectory.appending(path: "host-integration-mobile-\(language).png"))
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

@Observable @MainActor private final class HostIntegrationDraft {
    var mode = HostShellIntegrationMode.followGlobalSettings
}
