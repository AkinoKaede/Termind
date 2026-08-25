@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

@MainActor
final class AppleSpeechTranscriptionService: SpeechTranscriptionService {
    private let audioInput: any SpeechAudioInput
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sessionToken: UUID?

    init(audioInput: any SpeechAudioInput) {
        self.audioInput = audioInput
    }

    func requestAuthorization() async throws {
        let microphoneAllowed = await audioInput.requestAuthorization()
        guard microphoneAllowed else {
            throw SpeechTranscriptionFailure(.microphonePermissionDenied)
        }

        let speechStatus = await requestSpeechAuthorization()
        guard speechStatus == .authorized else {
            throw SpeechTranscriptionFailure(.speechPermissionDenied)
        }
    }

    func start(
        locale: Locale,
        eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void
    ) throws {
        cancel()

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechTranscriptionFailure(.recognizerUnavailable)
        }
        // Speech's Objective-C callbacks carry no actor-isolation information.
        // Pin them to the real main operation queue instead of relying on a
        // MainActor-inherited closure being invoked on the expected queue.
        recognizer.queue = .main

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let token = UUID()
        sessionToken = token
        self.recognizer = recognizer
        recognitionRequest = request
        recognitionTask = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeRecognitionHandler(
                service: self,
                token: token,
                eventHandler: eventHandler
            )
        )

        do {
            try audioInput.start(
                bufferHandler: Self.makeAudioBufferHandler(request: request),
                levelHandler: Self.makeAudioLevelHandler(eventHandler: eventHandler)
            )
        } catch let failure as SpeechTranscriptionFailure {
            cancel()
            throw failure
        } catch {
            cancel()
            throw SpeechTranscriptionFailure(.audioInputUnavailable, detail: error.localizedDescription)
        }
    }

    func finish() {
        audioInput.stop()
        recognitionRequest?.endAudio()
    }

    func cancel() {
        sessionToken = nil
        audioInput.stop()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognizer = nil
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { newStatus in
                continuation.resume(returning: newStatus)
            }
        }
    }

    nonisolated private static func makeRecognitionHandler(
        service: AppleSpeechTranscriptionService,
        token: UUID,
        eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { [weak service] result, error in
            // Reduce framework reference types to Sendable values before
            // crossing from Speech's callback queue to the main queue.
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            let failure = error.map(recognitionFailure(from:))
            // DispatchQueue.main.async establishes the queue identity required
            // by Speech and by Swift's actor data-race checks.
            DispatchQueue.main.async { [weak service] in
                MainActor.assumeIsolated {
                    guard let service, service.sessionToken == token else { return }
                    service.handleRecognitionResult(
                        transcript: transcript,
                        isFinal: isFinal,
                        failure: failure,
                        eventHandler: eventHandler
                    )
                }
            }
        }
    }

    nonisolated private static func makeAudioBufferHandler(
        request: SFSpeechAudioBufferRecognitionRequest
    ) -> SpeechAudioBufferHandler {
        let sink = SpeechRecognitionBufferSink(request: request)
        return { buffer in sink.append(buffer) }
    }

    nonisolated private static func makeAudioLevelHandler(
        eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void
    ) -> SpeechAudioLevelHandler {
        { level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    eventHandler(.level(level))
                }
            }
        }
    }

    private func handleRecognitionResult(
        transcript: String?,
        isFinal: Bool,
        failure: SpeechTranscriptionFailure?,
        eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void
    ) {
        if let transcript {
            if isFinal {
                audioInput.stop()
                eventHandler(.final(transcript))
            } else {
                eventHandler(.partial(transcript))
            }
        }
        if let failure {
            audioInput.stop()
            eventHandler(.failure(failure))
        }
    }

    nonisolated private static func recognitionFailure(from error: any Error) -> SpeechTranscriptionFailure {
        let nsError = error as NSError
        let description = nsError.localizedDescription
        let isNoSpeech =
            (nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110)
            || description.localizedCaseInsensitiveContains("no speech")
        return SpeechTranscriptionFailure(
            isNoSpeech ? .noSpeech : .recognitionFailed,
            detail: isNoSpeech ? nil : description
        )
    }

}

nonisolated private final class SpeechRecognitionBufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }
}
