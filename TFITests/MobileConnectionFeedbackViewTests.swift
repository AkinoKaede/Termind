import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized, .requiresKeyWindow) @MainActor
struct MobileConnectionFeedbackViewTests {
    @Test func onlyThePresentedForegroundJourneyProducesFeedbackAndRemountingDoesNotReplay() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = Host(name: "Feedback", host: "test.invalid")
        let journey = ConnectionJourney()
        let state = FeedbackState()
        let view = MobileConnectionJourneyView(
            journey: journey, library: HostLibraryModel(hosts: [host]),
            authenticationPrompt: nil, hostKey: nil, reconnectState: nil,
            submit: { _, _, _, _, _, _ in }, accept: { _ in }, retry: {}, retryReconnectNow: {},
            stopReconnecting: {}, cancel: {}
        )
        .environment(
            \.mobileConnectionFeedback,
            MobileConnectionFeedbackContext(
                isForeground: { state.foreground }, succeeded: { state.successes += 1 }))
        let controller = UIHostingController(rootView: AnyView(view))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            journey.hide()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        func begin() {
            journey.begin(host: host, route: [host], purpose: .metrics, username: nil)
        }
        begin()
        try await settle(window)
        journey.succeed()
        #expect(state.successes == 1)
        journey.succeed()
        #expect(state.successes == 1)

        controller.rootView = AnyView(Color.clear)
        try await settle(window)
        begin()
        journey.succeed()
        #expect(state.successes == 1)
        controller.rootView = AnyView(view)
        try await settle(window)
        #expect(state.successes == 1)
        begin()
        journey.succeed()
        #expect(state.successes == 2)

        state.foreground = false
        begin()
        journey.succeed()
        #expect(state.successes == 2)
        state.foreground = true
        try await settle(window)
        #expect(state.successes == 2)
        begin()
        journey.succeed()
        #expect(state.successes == 3)
    }

    private func settle(_ window: UIWindow) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
    }

    private final class FeedbackState {
        var foreground = true
        var successes = 0
    }
}
