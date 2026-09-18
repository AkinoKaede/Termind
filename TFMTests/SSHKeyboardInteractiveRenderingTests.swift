import AppKit
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing

@Suite(.serialized) @MainActor
struct SSHKeyboardInteractiveRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func rendersEchoAndSecretPrompts(_ language: String) async throws {
        let challenge = SSHKeyboardInteractiveChallenge(
            connectionID: UUID(), hostID: UUID(), hostname: "gateway.example.invalid", port: 22,
            username: "deploy", round: 1, name: "PAM", instruction: "Enter your account and verification code.",
            prompts: [.init(text: "Account", echo: true), .init(text: "Verification code", echo: false)])
        let view = SSHKeyboardInteractiveForm(challenge: challenge, submit: { _ in }, cancel: {})
            .padding(24).frame(width: 520)
            .environment(\.locale, Locale(identifier: language))
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        controller.view.layoutSubtreeIfNeeded()
        let fields = editableFields(in: controller.view)
        #expect(fields.count == 2)
        #expect(fields.filter { $0 is NSSecureTextField }.count == 1)
        #expect(fields.allSatisfy { $0.frame.height > 0 && $0.stringValue.isEmpty })
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "keyboard-interactive-\(language).png")
        let output = FileManager.default.temporaryDirectory.appending(path: "termind-keyboard-\(language).png")
        try data.write(to: output)
        print("Keyboard authentication snapshot: \(output.path)")
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, field.isEditable { return [field] }
        return view.subviews.flatMap { editableFields(in: $0) }
    }
}
