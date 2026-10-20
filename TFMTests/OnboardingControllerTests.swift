// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindPresentation
import Testing

@testable import Termind

@Suite
@MainActor
struct OnboardingControllerTests {
    @Test
    func quickOpenIsFirstAndOnlyAutomaticStepForTheLaunch() throws {
        let defaults = try makeDefaults()
        defer { clear(defaults) }
        let controller = OnboardingController(defaults: defaults)
        let window = WindowModel()
        controller.windowBecameActive(window)

        controller.consider(
            window: window,
            context: OnboardingContext(
                automaticQuickOpenReady: true,
                statusBarPath: pathContext,
                canGenerateCommand: true
            )
        )

        #expect(controller.presentation?.step == .quickOpen)
        controller.complete(.quickOpen)
        #expect(controller.isCompleted(.quickOpen))

        controller.consider(
            window: window,
            context: OnboardingContext(
                automaticQuickOpenReady: true,
                statusBarPath: pathContext,
                canGenerateCommand: true
            )
        )
        #expect(controller.presentation == nil)
    }

    @Test
    func statusBarPathWinsWhenBothContextualStepsAreEligible() throws {
        let defaults = try makeDefaults()
        defer { clear(defaults) }
        defaults.set(true, forKey: DesktopSettingsKey.onboardingQuickOpenCompleted)
        let controller = OnboardingController(defaults: defaults)
        let window = WindowModel()
        controller.windowBecameActive(window)

        controller.consider(
            window: window,
            context: OnboardingContext(
                automaticQuickOpenReady: true,
                statusBarPath: pathContext,
                canGenerateCommand: true
            )
        )

        #expect(controller.presentation?.step == .statusBarPath)
        #expect(controller.presentation?.pathDirection == .sshToSFTP)
    }

    @Test
    func commandGeneratorWaitsForItsRealContext() throws {
        let defaults = try makeDefaults()
        defer { clear(defaults) }
        defaults.set(true, forKey: DesktopSettingsKey.onboardingQuickOpenCompleted)
        defaults.set(true, forKey: DesktopSettingsKey.onboardingStatusBarPathCompleted)
        let controller = OnboardingController(defaults: defaults)
        let window = WindowModel()
        controller.windowBecameActive(window)

        controller.consider(window: window, context: OnboardingContext())
        #expect(controller.presentation == nil)

        controller.consider(
            window: window,
            context: OnboardingContext(canGenerateCommand: true)
        )
        #expect(controller.presentation?.step == .commandGenerator)
    }

    #if DEBUG
        @Test
        func previewBypassesCompletionWithoutChangingIt() throws {
            let defaults = try makeDefaults()
            defer { clear(defaults) }
            let controller = OnboardingController(defaults: defaults)
            let window = WindowModel()
            controller.windowBecameActive(window)

            controller.preview(.commandGenerator)
            controller.consider(window: window, context: OnboardingContext())
            guard
                case .waitingForContext = controller.developerStatus(
                    for: .commandGenerator
                )
            else {
                Issue.record("Expected Preview to wait for a shell context")
                return
            }
            controller.consider(
                window: window,
                context: OnboardingContext(canGenerateCommand: true)
            )
            #expect(controller.presentation?.mode == .preview)
            controller.complete(.commandGenerator)

            #expect(!controller.isCompleted(.commandGenerator))
            #expect(controller.presentation == nil)
            #expect(controller.previewRequest == nil)
        }

        @Test
        func resetAllClearsPersistenceAndLaunchThrottle() throws {
            let defaults = try makeDefaults()
            defer { clear(defaults) }
            let controller = OnboardingController(defaults: defaults)
            let window = WindowModel()
            controller.windowBecameActive(window)
            controller.consider(
                window: window,
                context: OnboardingContext(automaticQuickOpenReady: true)
            )
            controller.complete(.quickOpen)

            controller.resetAll()
            #expect(OnboardingStep.allCases.allSatisfy { !controller.isCompleted($0) })

            controller.consider(
                window: window,
                context: OnboardingContext(automaticQuickOpenReady: true)
            )
            #expect(controller.presentation?.step == .quickOpen)
        }
    #endif

    private var pathContext: OnboardingPathContext {
        OnboardingPathContext(
            direction: .sshToSFTP,
            hostID: UUID(),
            path: "/srv/app"
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "OnboardingControllerTests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suite))
    }

    private func clear(_ defaults: UserDefaults) {
        if let suite = defaults.volatileDomainNames.first(where: {
            $0.hasPrefix("OnboardingControllerTests.")
        }) {
            defaults.removePersistentDomain(forName: suite)
        }
        for step in OnboardingStep.allCases {
            defaults.removeObject(forKey: step.completionKey)
        }
    }
}
