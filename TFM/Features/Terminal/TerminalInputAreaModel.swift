// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindPresentation

nonisolated enum TerminalInputMode: String, CaseIterable {
    case input
    case commandGenerator

    var title: LocalizedStringResource {
        switch self {
        case .input: AppStrings.Settings.input
        case .commandGenerator: AppStrings.TerminalInput.generator
        }
    }
}

nonisolated enum TerminalInputAreaError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(localized: AppStrings.TerminalInput.unavailable)
    }
}

@Observable
final class TerminalInputAreaModel {
    static let minimumHeight = 96.0
    static let initialHeight = minimumHeight

    var draft = "" {
        didSet {
            guard draft != oldValue else { return }
            cancelGeneration()
            submissionError = nil
        }
    }
    var mode: TerminalInputMode = .input {
        didSet {
            guard mode != oldValue else { return }
            cancelGeneration()
            cancelTranscription()
            submissionError = nil
        }
    }
    private(set) var preferredHeight: Double
    private var focusedEditorID: UUID?
    private(set) var focusRequest: UInt64 = 0
    private(set) var submissionError: String?
    private let generation = CommandGenerationCoordinator()
    let transcriptionOwnerID = UUID()
    private var transcription: SpeechTranscriptionCoordinator?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionToken: UUID?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.double(forKey: DesktopSettingsKey.terminalInputAreaDefaultHeight)
        preferredHeight = saved.isFinite && saved > 0 ? saved : Self.initialHeight
    }

    var isGenerating: Bool { generation.isRunning }
    var isTranscribing: Bool {
        transcriptionTask != nil || transcription?.isOwned(by: transcriptionOwnerID) == true
    }
    var transcriptionError: SpeechTranscriptionFailure? {
        transcription?.errorOwnerID == transcriptionOwnerID ? transcription?.error : nil
    }
    var isEditorFocused: Bool { focusedEditorID != nil }
    var hasContent: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var error: String? {
        if let submissionError { return submissionError }
        if case .failed(let message) = generation.state { return message }
        return nil
    }

    static func height(_ preferred: Double, available: Double) -> Double {
        let maximum = max(0, available.isFinite ? available * 0.6 : 0)
        let minimum = min(minimumHeight, maximum)
        return min(max(preferred.isFinite ? preferred : initialHeight, minimum), maximum)
    }

    func resize(to height: Double, available: Double) {
        guard available > 0, height.isFinite else { return }
        let resized = Self.height(height, available: available)
        guard resized != Self.height(preferredHeight, available: available) else { return }
        preferredHeight = resized
        defaults.set(preferredHeight, forKey: DesktopSettingsKey.terminalInputAreaDefaultHeight)
    }

    @discardableResult
    func submit(deliver: (String) throws -> Void) -> Bool {
        guard mode == .input, hasContent, !isGenerating, !isTranscribing else { return false }
        do {
            try deliver(draft)
            draft = ""
            submissionError = nil
            requestEditorFocus()
            return true
        } catch {
            submissionError = error.localizedDescription
            requestEditorFocus()
            return false
        }
    }

    func generate(
        context: CommandGeneratorContext,
        using controller: any CommandGenerating,
        isCurrent: @escaping CommandGenerationCoordinator.IsCurrent
    ) {
        guard mode == .commandGenerator, hasContent, !isGenerating, !isTranscribing else { return }
        submissionError = nil
        generation.start(
            targetCount: 1,
            readContext: { context },
            isCurrent: isCurrent,
            generate: { try await controller.generate($0) },
            insert: { [weak self] command in
                guard let self else { return }
                self.draft = command
                self.mode = .input
                self.requestEditorFocus()
            }
        )
    }

    func failGeneration(_ message: String) {
        generation.fail(message)
    }

    func cancelGeneration() {
        generation.cancel()
    }

    func requestEditorFocus() {
        focusRequest &+= 1
    }

    func setEditorFocused(_ focused: Bool, editorID: UUID) {
        if focused {
            focusedEditorID = editorID
        } else if focusedEditorID == editorID {
            focusedEditorID = nil
        }
    }

    func dismissEditorFocus() {
        focusedEditorID = nil
    }

    func startTranscription(
        using coordinator: SpeechTranscriptionCoordinator, submit: @escaping () -> Void = {}
    ) {
        guard !isTranscribing, coordinator.canStart(for: transcriptionOwnerID) else { return }
        cancelGeneration()
        transcription = coordinator
        let token = UUID()
        transcriptionToken = token
        transcriptionTask = Task { [weak self] in
            guard let self, self.transcriptionToken == token, !Task.isCancelled else { return }
            await coordinator.start(ownerID: self.transcriptionOwnerID) { [weak self] text, shouldSubmit in
                guard let self, self.transcriptionToken == token else { return }
                self.transcriptionToken = nil
                self.transcriptionTask = nil
                self.applyTranscription(text)
                if shouldSubmit { submit() }
            }
            if self.transcriptionToken == token { self.transcriptionTask = nil }
        }
    }

    func applyTranscription(_ transcript: String) {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if draft.isEmpty || draft.last?.isWhitespace == true {
            draft += text
        } else {
            draft += " " + text
        }
        requestEditorFocus()
    }

    func stopTranscription() {
        transcription?.stop(ownerID: transcriptionOwnerID)
    }

    func submitTranscription() {
        transcription?.stop(ownerID: transcriptionOwnerID, sendAfterTranscription: true)
    }

    func cancelTranscription() {
        transcriptionToken = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcription?.cancel(ownerID: transcriptionOwnerID)
        dismissTranscriptionError()
    }

    func dismissTranscriptionError() {
        transcription?.dismissError(ownerID: transcriptionOwnerID)
    }

    func close() {
        cancelGeneration()
        cancelTranscription()
        draft = ""
        mode = .input
        dismissEditorFocus()
        submissionError = nil
    }
}
