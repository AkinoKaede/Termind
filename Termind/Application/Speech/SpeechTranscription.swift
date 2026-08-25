import Foundation

nonisolated enum SpeechTranscriptionEvent: Equatable, Sendable {
    case level(Float)
    case partial(String)
    case final(String)
    case failure(SpeechTranscriptionFailure)
}

nonisolated struct SpeechTranscriptionFailure: Error, Equatable, Sendable {
    nonisolated enum Code: Equatable, Sendable {
        case microphonePermissionDenied
        case speechPermissionDenied
        case recognizerUnavailable
        case audioInputUnavailable
        case noSpeech
        case recognitionFailed
    }

    let code: Code
    let detail: String?

    init(_ code: Code, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    var title: String {
        switch code {
        case .microphonePermissionDenied, .speechPermissionDenied:
            String(localized: "Transcription Permission Required")
        case .recognizerUnavailable:
            String(localized: "Transcription Unavailable")
        case .audioInputUnavailable:
            String(localized: "Microphone Unavailable")
        case .noSpeech:
            String(localized: "No Speech Detected")
        case .recognitionFailed:
            String(localized: "Transcription Failed")
        }
    }

    var message: String {
        switch code {
        case .microphonePermissionDenied:
            String(localized: "Allow Termind to use the microphone in System Settings, then try again.")
        case .speechPermissionDenied:
            String(localized: "Allow Termind to use Speech Recognition in System Settings, then try again.")
        case .recognizerUnavailable:
            String(localized: "Apple Speech Recognition is not currently available for your system language.")
        case .audioInputUnavailable:
            String(localized: "Termind could not start an audio input. Check that a microphone is connected and available.")
        case .noSpeech:
            String(localized: "No recognizable speech was captured. Try speaking closer to the microphone.")
        case .recognitionFailed:
            detail ?? String(localized: "Apple Speech Recognition could not transcribe this recording.")
        }
    }

    var offersSystemSettings: Bool {
        code == .microphonePermissionDenied || code == .speechPermissionDenied
    }
}

@MainActor
protocol SpeechTranscriptionService: AnyObject {
    func requestAuthorization() async throws
    func start(
        locale: Locale,
        eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void
    ) throws
    func finish()
    func cancel()
}

@Observable
@MainActor
final class SpeechTranscriptionCoordinator {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
    }

    typealias Completion = @MainActor (_ transcript: String, _ sendAfterTranscription: Bool) -> Void

    private(set) var phase: Phase = .idle
    private(set) var ownerID: UUID?
    private(set) var levelSamples: [Float]
    private(set) var isRequestingAuthorization = false
    private(set) var error: SpeechTranscriptionFailure?
    private(set) var errorOwnerID: UUID?

    private let service: any SpeechTranscriptionService
    private let sampleCount: Int
    private var activeToken: UUID?
    private var completion: Completion?
    private var sendAfterTranscription = false
    private var latestPartial = ""
    private var finalizationTimeout: Task<Void, Never>?

    init(
        service: any SpeechTranscriptionService,
        sampleCount: Int = 52
    ) {
        self.service = service
        self.sampleCount = max(8, sampleCount)
        levelSamples = Array(repeating: 0.04, count: max(8, sampleCount))
    }

    func isOwned(by ownerID: UUID) -> Bool {
        self.ownerID == ownerID
    }

    func canStart(for ownerID: UUID) -> Bool {
        self.ownerID == nil || self.ownerID == ownerID
    }

    @discardableResult
    func start(ownerID: UUID, completion: @escaping Completion) async -> Bool {
        guard self.ownerID == nil else { return false }

        let token = UUID()
        activeToken = token
        self.ownerID = ownerID
        self.completion = completion
        isRequestingAuthorization = true
        error = nil
        errorOwnerID = nil
        latestPartial = ""
        sendAfterTranscription = false
        levelSamples = Array(repeating: 0.04, count: sampleCount)

        do {
            try await service.requestAuthorization()
            guard activeToken == token else { return false }

            try service.start(locale: .autoupdatingCurrent) { [weak self] event in
                self?.handle(event, token: token)
            }
            guard activeToken == token else {
                service.cancel()
                return false
            }
            isRequestingAuthorization = false
            phase = .recording
            return true
        } catch {
            guard activeToken == token else { return false }
            fail(Self.failure(from: error), for: ownerID)
            return false
        }
    }

    func stop(ownerID: UUID, sendAfterTranscription: Bool = false) {
        guard self.ownerID == ownerID, phase == .recording else { return }
        self.sendAfterTranscription = sendAfterTranscription
        phase = .transcribing
        service.finish()
        scheduleFinalizationTimeout(for: ownerID, token: activeToken)
    }

    func cancel(ownerID: UUID) {
        guard self.ownerID == ownerID else { return }
        cancelActiveSession()
    }

    func cancelAll() {
        guard ownerID != nil else { return }
        cancelActiveSession()
    }

    func dismissError(ownerID: UUID) {
        guard errorOwnerID == ownerID else { return }
        error = nil
        errorOwnerID = nil
    }

    private func handle(_ event: SpeechTranscriptionEvent, token: UUID) {
        guard activeToken == token, let ownerID else { return }

        switch event {
        case .level(let level):
            guard phase == .recording else { return }
            levelSamples.removeFirst()
            levelSamples.append(min(max(level, 0.04), 1))
        case .partial(let transcript):
            latestPartial = transcript
        case .final(let transcript):
            finish(with: transcript, ownerID: ownerID)
        case .failure(let failure):
            fail(failure, for: ownerID)
        }
    }

    private func finish(with transcript: String, ownerID: UUID) {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            resetSession(cancelService: true)
            return
        }

        let shouldSend = sendAfterTranscription
        let completion = completion
        resetSession(cancelService: true)
        completion?(cleaned, shouldSend)
    }

    private func fail(_ failure: SpeechTranscriptionFailure, for ownerID: UUID) {
        resetSession(cancelService: true)
        // Silence is an ordinary outcome (for example an accidental tap), not
        // an actionable failure. Return to the composer without interrupting
        // the user with an alert.
        guard failure.code != .noSpeech else { return }
        error = failure
        errorOwnerID = ownerID
    }

    private func cancelActiveSession() {
        resetSession(cancelService: true)
    }

    private func resetSession(cancelService: Bool) {
        activeToken = nil
        finalizationTimeout?.cancel()
        finalizationTimeout = nil
        if cancelService { service.cancel() }
        phase = .idle
        ownerID = nil
        isRequestingAuthorization = false
        completion = nil
        sendAfterTranscription = false
        latestPartial = ""
    }

    private func scheduleFinalizationTimeout(for ownerID: UUID, token: UUID?) {
        guard let token else { return }
        finalizationTimeout?.cancel()
        finalizationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            guard let self, self.activeToken == token, self.phase == .transcribing else { return }
            if self.latestPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.resetSession(cancelService: true)
            } else {
                self.fail(
                    SpeechTranscriptionFailure(
                        .recognitionFailed,
                        detail: String(localized: "Apple Speech Recognition did not finish the transcription.")
                    ),
                    for: ownerID
                )
            }
        }
    }

    private static func failure(from error: any Error) -> SpeechTranscriptionFailure {
        if let failure = error as? SpeechTranscriptionFailure { return failure }
        return SpeechTranscriptionFailure(.recognitionFailed, detail: error.localizedDescription)
    }
}
