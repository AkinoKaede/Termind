import SwiftUI
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(
    .enabled(if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1"),
    .serialized)
@MainActor
struct MobileSFTPSettingsRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func connectionSettingsRenderSFTPDefaultsAndMaximumLimits(language: String) async throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: NavigationStack {
                MobileConnectionSettingsView(ssh: app.sshSettings, sftp: app.sftpSettings)
            }
            .environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        for value in [SFTPPreferences(), SFTPPreferences(globalLimit: 100, perHostLimit: 50)] {
            app.sftpSettings.applyRemoteSnapshot(value)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let data = try #require(image.pngData())
            Attachment.record(data, named: "mobile-connection-settings-\(language)-\(value.globalLimit).png")
        }
    }
}
