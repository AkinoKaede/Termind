import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

/// Opt-in native screenshots cover the connection states without opening a transport.
@Suite(.serialized) @MainActor
struct MobileConnectionJourneyRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func rendersInteractiveAuthentication(_ language: String) async throws {
        let host = TermindDomain.Host(name: "Production Gateway", host: "gateway.example.invalid")
        let library = HostLibraryModel(hosts: [host])
        let journey = ConnectionJourney()
        journey.begin(host: host, route: [host], purpose: .sshSession, username: "deploy")
        journey.waitForAuthentication(at: host.id)
        let queue = SSHKeyboardInteractiveQueue()
        let challenge = SSHKeyboardInteractiveChallenge(
            connectionID: UUID(), hostID: host.id, hostname: host.host, port: 22,
            username: "deploy", round: 1, name: "PAM", instruction: "Enter your account and verification code.",
            prompts: [.init(text: "Account", echo: true), .init(text: "Verification code", echo: false)])
        let request = Task { try await queue.request(challenge) }
        defer {
            queue.cancel(challenge.id)
            request.cancel()
        }
        for _ in 0..<100 where queue.current == nil { await Task.yield() }
        _ = try #require(queue.current)
        try await capture(
            "keyboard-interactive", language: language, scheme: .light,
            view: MobileConnectionJourneyView(
                journey: journey, library: library, authenticationPrompt: nil, hostKey: nil,
                reconnectState: nil, submit: { _, _, _, _, _, _ in }, accept: { _ in }, retry: {},
                retryReconnectNow: {}, stopReconnecting: {}, cancel: {}, keyboardAuthentication: queue))
    }

    @Test func renderConnectionJourneyStates() async throws {
        guard ProcessInfo.processInfo.environment["TERMIND_JOURNEY_SCREENSHOTS"] == "1" else { return }
        let host = TermindDomain.Host(name: "Production Gateway", host: "gateway.example.invalid")
        let library = HostLibraryModel(hosts: [host])

        for language in ["en", "zh-Hans", "zh-Hant"] {
            for scheme in [ColorScheme.light, .dark] {
                for state in JourneyFixtureState.allCases {
                    try await capture(
                        state.rawValue, language: language, scheme: scheme,
                        view: fixture(state, host: host, library: library))
                }
            }
            try await capture(
                "failure-large-type", language: language, scheme: .light,
                view: fixture(.failure, host: host, library: library)
                    .environment(\.dynamicTypeSize, .accessibility3))
        }
    }

    private func fixture(
        _ state: JourneyFixtureState, host: TermindDomain.Host, library: HostLibraryModel
    ) -> MobileConnectionJourneyView {
        let journey = ConnectionJourney()
        journey.begin(host: host, route: [host], purpose: .sshSession, username: "deploy")
        var prompt: SSHAuthenticationPrompt?
        var reconnect: ReconnectState?
        switch state {
        case .failure:
            journey.fail("The connection was refused by the remote host.", at: host.id)
        case .logs:
            journey.receive(.connecting(host.id))
            journey.log(endpoint: host.name, message: "Negotiating encryption and host keys")
            journey.showsLogs = true
        case .authentication:
            journey.waitForLocalIdentity(at: host.id, failure: "A username and password are required.")
            prompt = SSHAuthenticationPrompt(
                host: host, username: "deploy", failureMessage: "A username and password are required.")
        case .reconnection:
            journey.begin(
                host: host, route: [host], purpose: .sshSession, username: "deploy", mode: .reconnection)
            reconnect = ReconnectState(attempt: 2, nextRetry: .now.addingTimeInterval(12), lastError: "Network lost")
        }
        return MobileConnectionJourneyView(
            journey: journey, library: library, authenticationPrompt: prompt, hostKey: nil,
            reconnectState: reconnect, submit: { _, _, _, _, _, _ in }, accept: { _ in }, retry: {},
            retryReconnectNow: {}, stopReconnecting: {}, cancel: {})
    }

    private func capture<V: View>(
        _ name: String, language: String, scheme: ColorScheme, view: V
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: NavigationStack { view }
                .environment(\.locale, Locale(identifier: language))
                .preferredColorScheme(scheme))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        Attachment.record(data, named: "\(name)-\(language)-\(scheme == .dark ? "dark" : "light").png")
        let directory = FileManager.default.temporaryDirectory.appending(path: "journey-screenshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let appearance = scheme == .dark ? "dark" : "light"
        let output = directory.appending(path: "\(device)-\(language)-\(name)-\(appearance).png")
        try data.write(to: output)
        print("Journey snapshot: \(output.path)")
    }
}

private enum JourneyFixtureState: String, CaseIterable {
    case failure, logs, authentication, reconnection
}
