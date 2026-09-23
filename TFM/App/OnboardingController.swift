import Foundation
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

nonisolated enum OnboardingStep: String, CaseIterable, Identifiable, Sendable {
    case quickOpen
    case statusBarPath
    case commandGenerator

    nonisolated var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .quickOpen: AppStrings.Navigation.quickOpen
        case .statusBarPath: AppStrings.Onboarding.statusBarPath
        case .commandGenerator: AppStrings.Onboarding.commandGenerator
        }
    }

    var completionKey: String {
        switch self {
        case .quickOpen: DesktopSettingsKey.onboardingQuickOpenCompleted
        case .statusBarPath: DesktopSettingsKey.onboardingStatusBarPathCompleted
        case .commandGenerator: DesktopSettingsKey.onboardingCommandGeneratorCompleted
        }
    }
}

nonisolated enum OnboardingPathDirection: Hashable, Sendable {
    case sshToSFTP
    case sftpToSSH
}

nonisolated struct OnboardingPathContext: Hashable, Sendable {
    let direction: OnboardingPathDirection
    let hostID: Host.ID
    let path: String
}

nonisolated struct OnboardingContext: Hashable, Sendable {
    var canPresentCoachMark = true
    var automaticQuickOpenReady = false
    var statusBarPath: OnboardingPathContext?
    var canGenerateCommand = false
}

nonisolated struct OnboardingPresentation: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case automatic
        case preview
    }

    let step: OnboardingStep
    let windowID: ObjectIdentifier
    let mode: Mode
    let pathDirection: OnboardingPathDirection?
}

nonisolated enum OnboardingDeveloperStatus: Equatable, Sendable {
    case completed
    case pending
    case previewing
    case waitingForContext(LocalizedStringResource)

    var label: LocalizedStringResource {
        switch self {
        case .completed: AppStrings.Onboarding.completed
        case .pending: AppStrings.Onboarding.pending
        case .previewing: AppStrings.Onboarding.previewing
        case .waitingForContext: AppStrings.Onboarding.waitingForContext
        }
    }
}

/// App-wide arbitration for contextual onboarding.
///
/// Views report the context they can currently host. This object decides which
/// step owns the one coach mark allowed across every window, and keeps Preview
/// state separate from the completion flags a real user journey writes.
@MainActor @Observable
final class OnboardingController {
    private let defaults: UserDefaults
    private let automaticPresentationEnabled: Bool

    private(set) var presentation: OnboardingPresentation?
    private(set) var previewRequest: OnboardingStep?
    private(set) var previewWaitingReason: LocalizedStringResource?
    private(set) var revision: UInt64 = 0

    private var didAutomaticallyPresentThisLaunch = false
    private var activeWindowID: ObjectIdentifier?

    init(
        defaults: UserDefaults = .standard,
        automaticPresentationEnabled: Bool = true
    ) {
        self.defaults = defaults
        self.automaticPresentationEnabled = automaticPresentationEnabled
    }

    func windowClosed(_ window: WindowModel) {
        let id = ObjectIdentifier(window)
        if presentation?.windowID == id { presentation = nil }
        if activeWindowID == id { activeWindowID = nil }
        revision &+= 1
    }

    func windowBecameActive(_ window: WindowModel) {
        let windowID = ObjectIdentifier(window)
        if let presentation, presentation.windowID != windowID {
            self.presentation = nil
        }
        activeWindowID = windowID
        revision &+= 1
    }

    func consider(window: WindowModel, context: OnboardingContext) {
        let windowID = ObjectIdentifier(window)
        guard activeWindowID == nil || activeWindowID == windowID else { return }

        if let presentation {
            guard presentation.windowID == windowID else { return }
            if isEligible(presentation.step, in: context) { return }
            self.presentation = nil
        }

        guard context.canPresentCoachMark else {
            updatePreviewWaitingReason(for: context)
            return
        }

        if let previewRequest {
            guard isEligible(previewRequest, in: context) else {
                updatePreviewWaitingReason(for: context)
                return
            }
            present(previewRequest, in: windowID, mode: .preview, context: context)
            return
        }

        guard automaticPresentationEnabled, !didAutomaticallyPresentThisLaunch else { return }
        guard isCompleted(.quickOpen) else {
            guard context.automaticQuickOpenReady else { return }
            present(.quickOpen, in: windowID, mode: .automatic, context: context)
            return
        }

        if !isCompleted(.statusBarPath), context.statusBarPath != nil {
            present(.statusBarPath, in: windowID, mode: .automatic, context: context)
        } else if !isCompleted(.commandGenerator), context.canGenerateCommand {
            present(.commandGenerator, in: windowID, mode: .automatic, context: context)
        }
    }

    func complete(_ step: OnboardingStep) {
        if presentation?.step == step, presentation?.mode == .preview {
            finishPreview()
            return
        }
        defaults.set(true, forKey: step.completionKey)
        if presentation?.step == step { presentation = nil }
        revision &+= 1
    }

    func dismissCurrent() {
        guard let presentation else { return }
        if presentation.mode == .preview {
            finishPreview()
        } else {
            complete(presentation.step)
        }
    }

    func recordUse(of step: OnboardingStep) {
        complete(step)
    }

    func isCompleted(_ step: OnboardingStep) -> Bool {
        defaults.bool(forKey: step.completionKey)
    }

    #if DEBUG
        func developerStatus(for step: OnboardingStep) -> OnboardingDeveloperStatus {
            if presentation?.step == step, presentation?.mode == .preview {
                return .previewing
            }
            if previewRequest == step {
                return .waitingForContext(previewWaitingReason ?? AppStrings.Onboarding.waitingForWindow)
            }
            return isCompleted(step) ? .completed : .pending
        }

        func preview(_ step: OnboardingStep) {
            presentation = nil
            previewRequest = step
            previewWaitingReason = AppStrings.Onboarding.waitingForWindow
            revision &+= 1
        }

        func cancelPreview() {
            guard previewRequest != nil || presentation?.mode == .preview else { return }
            finishPreview()
        }

        func reset(_ step: OnboardingStep) {
            defaults.removeObject(forKey: step.completionKey)
            if presentation?.step == step { presentation = nil }
            if previewRequest == step {
                previewRequest = nil
                previewWaitingReason = nil
            }
            didAutomaticallyPresentThisLaunch = false
            revision &+= 1
        }

        func resetAll() {
            for step in OnboardingStep.allCases {
                defaults.removeObject(forKey: step.completionKey)
            }
            presentation = nil
            previewRequest = nil
            previewWaitingReason = nil
            didAutomaticallyPresentThisLaunch = false
            revision &+= 1
        }
    #endif

    private func present(
        _ step: OnboardingStep,
        in windowID: ObjectIdentifier,
        mode: OnboardingPresentation.Mode,
        context: OnboardingContext
    ) {
        presentation = OnboardingPresentation(
            step: step,
            windowID: windowID,
            mode: mode,
            pathDirection: step == .statusBarPath ? context.statusBarPath?.direction : nil
        )
        previewWaitingReason = nil
        if mode == .automatic { didAutomaticallyPresentThisLaunch = true }
        revision &+= 1
    }

    private func isEligible(_ step: OnboardingStep, in context: OnboardingContext) -> Bool {
        guard context.canPresentCoachMark else { return false }
        return switch step {
        case .quickOpen: true
        case .statusBarPath: context.statusBarPath != nil
        case .commandGenerator: context.canGenerateCommand
        }
    }

    private func updatePreviewWaitingReason(for context: OnboardingContext) {
        guard let previewRequest else { return }
        let reason: LocalizedStringResource
        if !context.canPresentCoachMark {
            reason = AppStrings.Onboarding.dismissCurrentPresentation
        } else {
            switch previewRequest {
            case .quickOpen:
                reason = AppStrings.Onboarding.waitingForActiveWindow
            case .statusBarPath:
                reason = AppStrings.Onboarding.pathPreviewRequirement
            case .commandGenerator:
                reason = AppStrings.Onboarding.commandPreviewRequirement
            }
        }
        if previewWaitingReason != reason {
            previewWaitingReason = reason
            revision &+= 1
        }
    }

    private func finishPreview() {
        presentation = nil
        previewRequest = nil
        previewWaitingReason = nil
        revision &+= 1
    }
}
