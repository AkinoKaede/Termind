import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct KeyExportRenderingTests {
    @Test(arguments: ["en", "zh-Hans"])
    func encryptedExportShowsItsPassphraseInsideTheVaultForm(_ language: String) async throws {
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "", passphrase: "secret")
        let key = SSHKeyRef(label: "Deployment Key", algorithm: .unknown, credentialRef: "key", hasPassphrase: true)
        let host = TermindDomain.Host(name: "Production", host: "server.example.com")
        let library = HostLibraryModel(hosts: [host], keys: [key])
        try library.upsert(key, credential: .software(SSHPrivateKeySecret(privateKey: material.privateKey)))
        let app = AppModel(hosts: library)
        let navigation = WindowModel()
        navigation.openVaultWork(.exportKey(key.id), on: .keychain)
        let controller = NSHostingController(
            rootView:
                VaultWorkspaceView().environment(app).environment(navigation)
                .environment(\.locale, Locale(identifier: language))
                .frame(width: 1040, height: 760))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.sizingOptions = []
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close()
            app.shutdownForTermination()
        }
        try await Task.sleep(for: .milliseconds(700))
        controller.view.layoutSubtreeIfNeeded()
        #expect(window.attachedSheet == nil)
        #expect(descendants(controller.view).contains { $0 is NSSecureTextField })
        #expect(app.externalAuthentication.pending.isEmpty)
        guard let image = controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds) else {
            Issue.record("Unable to capture export form")
            return
        }
        controller.view.cacheDisplay(in: controller.view.bounds, to: image)
        let directory = FileManager.default.temporaryDirectory.appending(path: "key-export-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "macos-\(language)-form.png")
        let data = try #require(image.representation(using: .png, properties: [:]))
        Attachment.record(data, named: output.lastPathComponent)
        try data.write(to: output)
        print("Key export snapshot: \(output.path)")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}
