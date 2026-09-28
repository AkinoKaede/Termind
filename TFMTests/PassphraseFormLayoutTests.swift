import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@Suite @MainActor
struct PassphraseFormLayoutTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func passphraseActionsFitTheAuthenticationCard(language: String, allowsSaving: Bool) throws {
        let host = TermindDomain.Host(name: "Production", host: "server.example.invalid")
        let prompt = SSHAuthenticationPrompt(
            host: host, username: "deploy", requiresPassphrase: true, allowsSaving: allowsSaving)
        let view = NSHostingView(
            rootView: SSHAuthenticationForm(
                prompt: prompt, submit: { _, _, _, _, _, _ in }, cancel: {}, library: HostLibraryModel()
            ).environment(\.locale, Locale(identifier: language)).frame(width: 420))
        let size = view.fittingSize
        #expect(size.width == 420)
        #expect(size.height > 100 && size.height < 400)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["TERMIND_PASSPHRASE_PREVIEW"] == "1", allowsSaving {
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                "termind-passphrase-macos-\(language).png")
            try png.write(to: url)
            print("Passphrase preview: \(url.path)")
        }
    }
}
