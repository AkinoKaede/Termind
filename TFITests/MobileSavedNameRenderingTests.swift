import AgentKit
import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(
    .requiresKeyWindow,
    .serialized)
@MainActor
struct MobileSavedNameRenderingTests {
    @Test func forwardingNameHasNoPlaceholderUntilAHostIsSelected() async throws {
        let draft = ForwardingNameDraft()
        let controller = UIHostingController(rootView: ForwardingNameForm(draft: draft))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 900))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let field = try #require(emptyNameField(in: controller.view))
        #expect(field.placeholder?.isEmpty != false)
        draft.host = .init(id: draft.rule.hostID, name: "AWS", host: "example.invalid")
        try await Task.sleep(for: .milliseconds(100))
        #expect(field.placeholder == "AWS (-L)")
        draft.rule.kind = .dynamic
        try await Task.sleep(for: .milliseconds(100))
        #expect(field.placeholder == "AWS (-D)")
        draft.host = nil
        try await Task.sleep(for: .milliseconds(100))
        #expect(field.placeholder?.isEmpty != false)
        #expect(draft.rule.label.isEmpty)
    }

    private func emptyNameField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField, field.text?.isEmpty != false { return field }
        return view.subviews.lazy.compactMap { emptyNameField(in: $0) }.first
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func blankNameFormsPreviewTheSavedDefaults(_ language: String) async throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "AWS", host: "example.invalid")
        #expect(app.library.saveHost(host))
        try await capture(
            MobileForwardingEditor(app: app, rule: .init(hostID: host.id), isNew: true),
            language: language, name: "forwarding")
        let generator = MobileKeyEditorModel(mode: .generate, credentials: app.credentials)
        generator.algorithm = .rsa
        try await capture(MobileKeyEditor(model: generator), language: language, name: "key")
        let enclave = SSHKeyRef(label: "", algorithm: .ecdsa256, storage: .secureEnclave)
        let editor = MobileKeyEditorModel(mode: .edit, credentials: app.credentials, key: enclave)
        try await capture(MobileKeyEditor(model: editor), language: language, name: "enclave")
        try await capture(
            NavigationStack {
                Form {
                    HostOrganizationSection(host: .constant(.init(name: "", host: "example.invalid"))) {
                        EmptyView()
                    } tagsField: {
                        EmptyView()
                    }
                    HostConnectionFields(host: .constant(.init(name: "", host: "example.invalid")))
                    MobileModelFields(
                        model: .constant(AIModel(id: "private-model")), provider: ModelProvider(name: "Gateway"))
                }
            }, language: language, name: "host-model")
    }

    private func capture(_ content: some View, language: String, name: String) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: content.environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let bytes = try #require(image.pngData())
        Attachment.record(bytes, named: "name-hints-\(name)-\(language).png")
        #expect(bytes.count > 10_000)
    }
}

@Observable @MainActor
private final class ForwardingNameDraft {
    var rule = PortForwardingRule(hostID: UUID())
    var host: TermindDomain.Host?
}

private struct ForwardingNameForm: View {
    @Bindable var draft: ForwardingNameDraft
    var body: some View { Form { PortForwardingFields(rule: $draft.rule, hosts: draft.host.map { [$0] } ?? []) } }
}
