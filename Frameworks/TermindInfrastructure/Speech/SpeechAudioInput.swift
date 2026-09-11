@preconcurrency import AVFoundation
import TermindApplication

public typealias SpeechAudioBufferHandler = @Sendable (AVAudioPCMBuffer) -> Void
public typealias SpeechAudioLevelHandler = @Sendable (Float) -> Void

/// Apple Speech consumes PCM buffers, while each supported OS owns the
/// permission and audio-device lifecycle used to produce them.
@MainActor
public protocol SpeechAudioInput: AnyObject {
    func requestAuthorization() async -> Bool
    func start(
        bufferHandler: @escaping SpeechAudioBufferHandler,
        levelHandler: @escaping SpeechAudioLevelHandler
    ) throws
    func stop()
}
