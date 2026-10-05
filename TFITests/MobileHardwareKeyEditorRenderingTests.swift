import CryptoKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UIKit

@testable import TermindIOS

@Suite(
    .requiresKeyWindow,
    .serialized)
@MainActor
struct MobileHardwareKeyEditorRenderingTests {
    @Test(arguments: ["en", "zh-Hans"], [false, true])
    func hardwareKeyEditorsUseNativeActionsAndCompactStorageRows(language: String, enclave: Bool) async throws {
        let key: SSHKeyRef
        if enclave {
            key = SSHKeyRef(
                label: "Device Key", algorithm: .ecdsa256,
                publicKey: "ecdsa-sha2-nistp256 " + String(repeating: "AAAA", count: 40),
                fingerprint: "SHA256:fixture", storage: .secureEnclave)
        } else {
            key = try WebAuthnSSH.keyReference(
                SecurityKeyCredential(
                    credentialID: Data(repeating: 1, count: 64),
                    publicKeyX963: P256.Signing.PrivateKey().publicKey.x963Representation), label: "Hardware Key")
        }
        let credentials = CredentialLibraryModel(library: HostLibraryModel(keys: [key]))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: HardwareKeyEditorHost(credentials: credentials, key: key, enclave: enclave)
                .environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(800))
        let sheet = try #require(controller.presentedViewController)
        sheet.view.layoutIfNeeded()
        let navigation = try #require(descendant(UINavigationController.self, in: sheet))
        let item = try #require(navigation.topViewController?.navigationItem)
        let buttons =
            item.leadingItemGroups.flatMap(\.barButtonItems)
            + item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
        let names = Set(buttons.compactMap { $0.accessibilityLabel ?? $0.title })
        #expect(!names.isDisjoint(with: ["Save", "保存"]))
        #expect(!names.isDisjoint(with: ["Cancel", "取消"]))
        let collection = try #require(descendant(UICollectionView.self, in: sheet.view))
        let storage = try #require(collection.cellForItem(at: IndexPath(item: 0, section: 1)))
        #expect(storage.bounds.height < 100, "Storage row height: \(storage.bounds.height)")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        let directory = FileManager.default.temporaryDirectory.appending(path: "hardware-key-editors")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let output = directory.appending(path: "\(device)-\(enclave ? "enclave" : "security-key")-\(language).png")
        try data.write(to: output)
        print("Hardware key editor snapshot: \(output.path)")
    }

    private func descendant<T: UIViewController>(_ type: T.Type, in controller: UIViewController) -> T? {
        if let value = controller as? T { return value }
        return controller.children.lazy.compactMap { descendant(type, in: $0) }.first
    }

    private func descendant<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let value = view as? T { return value }
        return view.subviews.lazy.compactMap { descendant(type, in: $0) }.first
    }
}

private struct HardwareKeyEditorHost: View {
    let credentials: CredentialLibraryModel
    let key: SSHKeyRef
    let enclave: Bool
    @State private var presented = true

    var body: some View {
        Color.clear.sheet(isPresented: $presented) {
            if enclave {
                MobileKeyEditor(model: MobileKeyEditorModel(mode: .edit, credentials: credentials, key: key))
            } else {
                SecurityKeyEditor(credentials: credentials, existing: key)
            }
        }
    }
}
