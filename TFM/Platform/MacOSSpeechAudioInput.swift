// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

@preconcurrency import AVFoundation
import Foundation
import TermindApplication
import TermindInfrastructure

/// macOS microphone permission and AVAudioEngine lifecycle for Apple Speech.
@MainActor
final class MacOSSpeechAudioInput: SpeechAudioInput {
    private let audioEngine = AVAudioEngine()
    private var inputTapInstalled = false

    func requestAuthorization() async -> Bool {
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

    func start(
        bufferHandler: @escaping SpeechAudioBufferHandler,
        levelHandler: @escaping SpeechAudioLevelHandler
    ) throws {
        stop()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechTranscriptionFailure(.audioInputUnavailable)
        }

        // AVAudioEngine invokes this tap on its realtime audio queue, so the
        // closure must be created outside MainActor isolation.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: format,
            block: Self.makeAudioTapHandler(
                bufferHandler: bufferHandler,
                levelHandler: levelHandler
            )
        )
        inputTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            stop()
            throw SpeechTranscriptionFailure(
                .audioInputUnavailable,
                detail: error.localizedDescription
            )
        }
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        if inputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
    }

    nonisolated private static func makeAudioTapHandler(
        bufferHandler: @escaping SpeechAudioBufferHandler,
        levelHandler: @escaping SpeechAudioLevelHandler
    ) -> AVAudioNodeTapBlock {
        let levelGate = AudioLevelDeliveryGate(maximumUpdatesPerSecond: 30)
        return { buffer, _ in
            bufferHandler(buffer)
            guard levelGate.shouldDeliver() else { return }
            levelHandler(normalizedLevel(from: buffer))
        }
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
