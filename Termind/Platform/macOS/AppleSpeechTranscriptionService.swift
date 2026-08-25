@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

@MainActor
final class AppleSpeechTranscriptionService: SpeechTranscriptionService {
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sessionToken: UUID?
    private var inputTapInstalled = false

    func requestAuthorization() async throws {
        let microphoneAllowed = await requestMicrophoneAuthorization()
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

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechTranscriptionFailure(.audioInputUnavailable)
        }

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

        // Build the tap block in a nonisolated context. A closure created
        // directly in this @MainActor method inherits main-actor isolation,
        // but AVAudioEngine invokes it on its realtime audio queue. In Swift 6
        // that mismatch traps with a libdispatch main-queue precondition.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: Self.makeAudioTapHandler(request: request, eventHandler: eventHandler)
        )
        inputTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            cancel()
            throw SpeechTranscriptionFailure(.audioInputUnavailable, detail: error.localizedDescription)
        }
    }

    func finish() {
        stopCapturingAudio()
        recognitionRequest?.endAudio()
    }

    func cancel() {
        sessionToken = nil
        stopCapturingAudio()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        recognizer = nil
    }

    private func stopCapturingAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
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

    nonisolated private static func makeAudioTapHandler(
        request: SFSpeechAudioBufferRecognitionRequest,
        eventHandler: @escaping @MainActor (SpeechTranscriptionEvent) -> Void
    ) -> AVAudioNodeTapBlock {
        let levelGate = AudioLevelDeliveryGate(maximumUpdatesPerSecond: 30)
        return { buffer, _ in
            request.append(buffer)

            let level = normalizedLevel(from: buffer)
            guard levelGate.shouldDeliver() else { return }
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
                stopCapturingAudio()
                eventHandler(.final(transcript))
            } else {
                eventHandler(.partial(transcript))
            }
        }
        if let failure {
            stopCapturingAudio()
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

    nonisolated private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0.04 }
        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return min(max((decibels + 58) / 58, 0.04), 1)
    }
}

nonisolated private final class AudioLevelDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private var lastDeliveryTime: TimeInterval = 0

    init(maximumUpdatesPerSecond: Double) {
        minimumInterval = 1 / maximumUpdatesPerSecond
    }

    func shouldDeliver(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard now - lastDeliveryTime >= minimumInterval else { return false }
        lastDeliveryTime = now
        return true
    }
}
