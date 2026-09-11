@preconcurrency import AVFoundation
import Foundation
import TermindApplication
import TermindInfrastructure

@MainActor
final class IOSSpeechAudioInput: SpeechAudioInput {
    var onInterruption: (() -> Void)?
    private var engine: AVAudioEngine?
    private var interrupted: (any NSObjectProtocol)?
    private var hasSession = false

    func requestAuthorization() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start(bufferHandler: @escaping SpeechAudioBufferHandler, levelHandler: @escaping SpeechAudioLevelHandler)
        throws
    {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
        hasSession = true
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            throw SpeechTranscriptionFailure(.audioInputUnavailable)
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            bufferHandler(buffer)
            if let values = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var square: Float = 0
                for i in 0..<Int(buffer.frameLength) { square += values[i] * values[i] }
                levelHandler(min(1, sqrt(square / Float(buffer.frameLength)) * 8))
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
        interrupted = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
                self?.onInterruption?()
            }
        }
    }

    func stop() {
        if let interrupted { NotificationCenter.default.removeObserver(interrupted) }
        interrupted = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        if hasSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            hasSession = false
        }
    }
}
