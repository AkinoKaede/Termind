import AgentKit
import SwiftUI
import TermindApplication
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UIKit
import Vision

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileAssistantInteractionRenderingTests {
    @Test func approvalTextRetainsItsNaturalHeight() {
        func height(_ text: String) -> CGFloat {
            let controller = UIHostingController(
                rootView: AssistantApprovalDetails(
                    detail: AgentToolDetail(items: [.text(.init(text: text, style: .monospaced))]),
                    reasons: [], showsSafetyDetails: .constant(false)
                )
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, .large))
            return controller.sizeThatFits(in: CGSize(width: 340, height: 600)).height
        }
        let single = height("sudo systemctl restart nginx")
        let multiple = height("cd /srv/app\npwd\nsudo systemctl restart nginx")
        #expect(single >= 12)
        #expect(multiple >= single * 2.5)
    }

    @Test func keyboardAuthenticationMeasuresItsVisibleFields() async throws {
        func height(promptCount: Int) -> CGFloat {
            let challenge = SSHKeyboardInteractiveChallenge(
                connectionID: UUID(), hostID: UUID(), hostname: "prod.example.com", port: 22,
                username: "deploy", round: 1, name: "", instruction: "",
                prompts: (0..<promptCount).map { .init(text: "Verification code \($0)", echo: false) })
            let controller = UIHostingController(
                rootView: SSHKeyboardInteractiveForm(challenge: challenge, submit: { _ in }, cancel: {})
                    .fixedSize(horizontal: false, vertical: true)
                    .environment(\.dynamicTypeSize, .large))
            return controller.sizeThatFits(in: CGSize(width: 340, height: 600)).height
        }
        let single = height(promptCount: 1)
        let multiple = height(promptCount: 3)
        #expect(single > 100)
        #expect(multiple > single + 80)

        let app = try MobileAppModel(inMemory: true)
        let conversation = ConversationModel()
        let challenge = SSHKeyboardInteractiveChallenge(
            connectionID: UUID(), hostID: UUID(), hostname: "prod.example.com", port: 22,
            username: "deploy", round: 1, name: "Account verification", instruction: "Verify your account.",
            prompts: [.init(text: "Account", echo: true), .init(text: "Verification code", echo: false)])
        let request = AgentSSHAuthenticationRequest(
            invocationID: UUID(), hostID: UUID(), displayName: "Production", address: "prod.example.com",
            mode: .keyboardInteractive(challenge), username: "deploy")
        let response = Task { await conversation.requestSSHAuthentication(request) }
        for _ in 0..<100 where conversation.pendingSSHAuthentication == nil { await Task.yield() }
        _ = try #require(conversation.pendingSSHAuthentication)
        defer { conversation.respondToSSHAuthentication(.cancelled) }
        try await capture(
            "keyboard-layout", dark: true, language: "en", large: true, expected: ["prod.example"],
            view: MobileAssistantInteraction(conversation: conversation, hosts: app.library))
        conversation.respondToSSHAuthentication(.cancelled)
        _ = await response.value
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func interactionTextRemainsVisibleOnMaterial(_ language: String) async throws {
        try await renderInteractions(language: language, large: false)
    }

    @Test func interactionTextRemainsVisibleWithLargeType() async throws {
        try await renderInteractions(language: "en", large: true)
    }

    private func renderInteractions(language: String, large: Bool) async throws {
        let app = try MobileAppModel(inMemory: true)
        let conversation = ConversationModel()
        for dark in [false, true] {
            for (name, arguments, expected) in approvalFixtures {
                let request = approval(name, arguments: arguments)
                let response = Task { await conversation.requestApproval(request) }
                for _ in 0..<100 where conversation.pendingApproval == nil { await Task.yield() }
                _ = try #require(conversation.pendingApproval)
                defer { conversation.respondToApproval(request.id, allow: false) }
                let detail = AgentToolPresentation.approval(
                    for: request, presenter: TermindAgentTools.presenter(for: request.descriptor)
                ).detail
                #expect(AgentToolDetailPreview(detail).fullText.contains(expected))
                try await capture(
                    name, dark: dark, language: language, large: large,
                    expected: [expected]
                        + (language == "en" && name == "ssh_exec" ? ["Command", "Working directory"] : []),
                    view: MobileAssistantInteraction(conversation: conversation, hosts: app.library))
                conversation.respondToApproval(request.id, allow: false)
                _ = await response.value
            }

            let challenge = SSHKeyboardInteractiveChallenge(
                connectionID: UUID(), hostID: UUID(), hostname: "prod.example.com", port: 22,
                username: "deploy", round: 1, name: "Account verification", instruction: "Verify your account.",
                prompts: [.init(text: "Account", echo: true), .init(text: "Verification code", echo: false)])
            let modes: [(String, AgentSSHAuthenticationRequest.Mode)] = [
                ("identity", .identity), ("passphrase", .passphrase(keyID: UUID())),
                ("keyboard", .keyboardInteractive(challenge)),
            ]
            for (name, mode) in modes {
                let request = AgentSSHAuthenticationRequest(
                    invocationID: UUID(), hostID: UUID(), displayName: "Production", address: "prod.example.com",
                    mode: mode, username: "deploy", failureMessage: "Authentication failed")
                let response = Task { await conversation.requestSSHAuthentication(request) }
                for _ in 0..<100 where conversation.pendingSSHAuthentication == nil { await Task.yield() }
                _ = try #require(conversation.pendingSSHAuthentication)
                defer { conversation.respondToSSHAuthentication(.cancelled) }
                try await capture(
                    name, dark: dark, language: language, large: large,
                    expected: ["prod.example"],
                    view: MobileAssistantInteraction(conversation: conversation, hosts: app.library))
                conversation.respondToSSHAuthentication(.cancelled)
                _ = await response.value
            }

            let request = AgentSSHHostKeyRequest(
                invocationID: UUID(), hostID: UUID(), displayName: "Production", address: "prod.example.com",
                prompt: SSHHostKeyPrompt(
                    observation: .init(
                        hostname: "prod.example.com", port: 22, algorithm: .ed25519,
                        fingerprint: "SHA256:W8RAGx7gKfJxHk2m7M8y5XoQn4tS9cA6bP3dL1uV0eE"),
                    kind: .additionalKey(trustedKeyCount: 1)), allowsPersistentTrust: true)
            let response = Task { await conversation.requestSSHHostKeyConfirmation(request) }
            for _ in 0..<100 where conversation.pendingSSHHostKey == nil { await Task.yield() }
            _ = try #require(conversation.pendingSSHHostKey)
            defer { conversation.respondToSSHHostKey(.deny) }
            try await capture(
                "host-key", dark: dark, language: language, large: large, expected: ["prod.example"],
                view: MobileAssistantInteraction(conversation: conversation, hosts: app.library))
            conversation.respondToSSHHostKey(.deny)
            _ = await response.value

            let choices = [
                AgentUserInputOption(id: "first", label: "Restart service", detail: "Apply the new configuration."),
                AgentUserInputOption(id: "second", label: "Review logs", detail: "Inspect the latest service output."),
            ]
            let questions: [(String, AgentUserQuestion.Kind)] = [
                ("text", .text), ("secret", .secret),
                ("choice", .choice(.init(options: choices, allowsCustomAnswer: true))),
                ("multiple", .choice(.init(options: choices, allowsCustomAnswer: true, allowsMultipleAnswers: true))),
            ]
            for (name, kind) in questions {
                conversation.present(
                    .init(questions: [
                        .init(id: "answer", header: "Deployment", prompt: "Confirm the next step.", kind: kind)
                    ]))
                defer { conversation.cancelUserInput() }
                try await capture(
                    name, dark: dark, language: language, large: large, expected: ["Deployment"],
                    view: MobileAssistantInteraction(conversation: conversation, hosts: app.library))
                conversation.cancelUserInput()
            }
        }
    }

    private var approvalFixtures: [(String, [String: AgentJSONValue], String)] {
        [
            (
                "ssh_exec",
                [
                    "command": .string("cd /srv/app\nsudo systemctl restart nginx\nsystemctl status nginx --no-pager"),
                    "cwd": .string("/srv/app"),
                ], "sudo"
            ),
            (
                "sftp_write",
                ["path": .string("/srv/app/config"), "content": .string("maintenance=true\nservice=nginx")],
                "maintenance"
            ),
            ("remote_tool", ["payload": .string("deployment\nservice=nginx\nrestart=true")], "deployment"),
            (
                "memory",
                [
                    "operations": .array([
                        .object([
                            "action": .string("add"), "target": .string("user"),
                            "content": .string("Review deployment logs."),
                        ])
                    ])
                ], "deployment"
            ),
        ]
    }

    private func approval(_ name: String, arguments: [String: AgentJSONValue]) -> AgentApprovalRequest {
        let request = AgentApprovalRequest(
            invocation: AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(id: "render-approval", name: name, arguments: .object(arguments))),
            descriptor: AgentToolDescriptor(
                name: name, summary: name, inputSchema: .object([:]),
                target: name == "remote_tool" ? .mcp : .host, approvalPolicy: .ask,
                presentation: name == "remote_tool"
                    ? nil
                    : .init(
                        symbol: "terminal", activity: .label(name), presenterID: "builtin.\(name)")),
            userIntent: "Restart the service", localReasons: [])
        return request
    }

    private func capture<V: View>(
        _ name: String, dark: Bool, language: String, large: Bool, expected: [String], view: V
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let controller = UIHostingController(
            rootView: VStack {
                Spacer()
                view
            }
            .padding(16)
            .background(Color(uiColor: .systemBackground))
            .environment(\.locale, Locale(identifier: language))
            .environment(\.dynamicTypeSize, large ? .accessibility2 : .large)
            .environment(\.colorScheme, dark ? .dark : .light))
        window.rootViewController = controller
        window.windowLevel = .alert + 2
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "interaction-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(language)-\(name)-\(dark ? "dark" : "light")-\(large ? "large" : "normal").png"
        let url = directory.appending(path: filename)
        let data = try #require(image.pngData())
        try data.write(to: url)
        Attachment.record(data, named: filename)
        // Layout and accessibility can both succeed while the actual glyphs are invisible.
        // Recognize the rendered pixels to catch the material/foreground regression.
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: #require(image.cgImage)).perform([recognition])
        let visibleText = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
            separator: " ")
        // OCR may insert spaces around punctuation in monospaced addresses.
        let normalizedText = visibleText.filter { !$0.isWhitespace }
        for text in expected {
            #expect(
                normalizedText.localizedCaseInsensitiveContains(text.filter { !$0.isWhitespace }),
                "\(filename): \(visibleText)")
        }
        print("Interaction snapshot: \(url.path)")
    }
}
