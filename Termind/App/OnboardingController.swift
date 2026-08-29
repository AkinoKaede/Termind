import Foundation

nonisolated enum OnboardingStep: String, CaseIterable, Identifiable, Sendable {
    case quickOpen
    case statusBarPath
    case commandGenerator

    nonisolated var id: Self { self }

    var title: String {
        switch self {
        case .quickOpen: "Quick Open"
        case .statusBarPath: "Status Bar Path"
        case .commandGenerator: "Command Generator"
        }
    }

    var completionKey: String {
        switch self {
        case .quickOpen: SettingsKey.onboardingQuickOpenCompleted
        case .statusBarPath: SettingsKey.onboardingStatusBarPathCompleted
        case .commandGenerator: SettingsKey.onboardingCommandGeneratorCompleted
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
    case waitingForContext(String)

    var label: String {
        switch self {
        case .completed: "Completed"
        case .pending: "Pending"
        case .previewing: "Previewing"
        case .waitingForContext: "Waiting for Context"
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
    private(set) var previewWaitingReason: String?
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

    func isPresenting(_ step: OnboardingStep, in window: WindowModel) -> Bool {
        presentation?.step == step && presentation?.windowID == ObjectIdentifier(window)
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
                return .waitingForContext(previewWaitingReason ?? "Waiting for an active window.")
            }
            return isCompleted(step) ? .completed : .pending
        }

        func preview(_ step: OnboardingStep) {
            presentation = nil
            previewRequest = step
            previewWaitingReason = "Waiting for an active window."
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
        let reason: String
        if !context.canPresentCoachMark {
            reason = "Close the current sheet, popover, or command palette."
        } else {
            switch previewRequest {
            case .quickOpen:
                reason = "Waiting for an active app window."
            case .statusBarPath:
                reason = "Open a connected SSH or SFTP session with an expanded Status Bar and a known path."
            case .commandGenerator:
                reason = "Focus a supported SSH shell prompt with Shell Integration and a configured Command Generator."
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
