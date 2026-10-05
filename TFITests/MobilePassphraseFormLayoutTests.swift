import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobilePassphraseFormLayoutTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [320.0, 600.0])
    func passphraseActionsFitCompactAndRegularWidths(language: String, width: Double) throws {
        let host = TermindDomain.Host(name: "Production", host: "server.example.invalid")
        let prompt = SSHAuthenticationPrompt(host: host, username: "deploy", requiresPassphrase: true)
        let controller = UIHostingController(
            rootView: SSHAuthenticationForm(
                prompt: prompt, submit: { _, _, _, _, _, _ in }, cancel: {}, library: HostLibraryModel()
            ).environment(\.locale, Locale(identifier: language)).frame(width: width))
        let size = controller.sizeThatFits(in: CGSize(width: width, height: 1000))
        #expect(abs(size.width - width) < 1)
        #expect(size.height > 100 && size.height < 500)
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.layoutIfNeeded()
    }

    @Test(
        .requiresKeyWindow,
        arguments: ["en", "zh-Hans"], [false, true])
    func rendersPassphraseActionsInANativeWindow(language: String, showKeys: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let host = TermindDomain.Host(name: "Production", host: "server.example.invalid")
        let prompt = SSHAuthenticationPrompt(host: host, username: "deploy", requiresPassphrase: true)
        let app = try MobileAppModel(inMemory: true)
        for saved in [false, true] {
            let key = SSHKeyRef(
                label: saved ? "Saved Key" : "Unsaved Key", publicKey: "ssh-ed25519 fixture",
                credentialRef: "termind.key.\(UUID())", hasPassphrase: true)
            try app.credentials.upsert(
                key, credential: .software(.init(privateKey: "fixture", passphrase: saved ? "fixture-phrase" : nil)))
        }
        let controller = UIHostingController(
            rootView: Group {
                if showKeys {
                    NavigationStack { MobileCredentialsView(app: app) }
                } else {
                    SSHAuthenticationForm(
                        prompt: prompt, submit: { _, _, _, _, _, _ in }, cancel: {}, library: app.library
                    ).frame(width: 320).padding()
                }
            }.environment(\.locale, Locale(identifier: language)))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "termind-passphrase-ios-\(language)-\(showKeys ? "keys" : "form").png")
        try data.write(to: url)
        print("Passphrase preview: \(url.path)")
    }
}
