// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AudioToolbox
import Foundation
import Synchronization
import Testing

@testable import TermindIOS

@MainActor
struct MobileSystemSoundPlayerTests {
    @Test func sharedBellResourceIsBundledAsWaveAudio() throws {
        let url = try #require(TerminalNotificationPlatform.soundURL)
        #expect(url.lastPathComponent == "bell.wav")
        let data = try Data(contentsOf: url)
        #expect(String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE")
    }

    @Test func completionCanDisposeOnTheAudioQueueWithoutReenteringTheMainActor() async throws {
        let completions = Mutex<[@Sendable () -> Void]>([])
        let started = Mutex<[SystemSoundID]>([])
        let disposed = Mutex<[SystemSoundID]>([])
        let nextSound = Mutex<SystemSoundID>(40)
        let player = MobileSystemSoundPlayer(
            create: { _ in
                nextSound.withLock {
                    $0 += 1
                    return $0
                }
            },
            start: { sound, completion in
                started.withLock { $0.append(sound) }
                completions.withLock { $0.append(completion) }
            },
            dispose: { sound in
                #expect(!Thread.isMainThread)
                disposed.withLock { $0.append(sound) }
            })
        let url = URL(fileURLWithPath: "/unused.wav")
        player.play(url: url)
        player.play(url: url)
        #expect(started.withLock { $0 } == [41, 42])
        #expect(disposed.withLock { $0.isEmpty })

        let callbacks = completions.withLock { $0 }
        #expect(callbacks.count == 2)
        await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.audio-completion").async {
                for callback in callbacks.reversed() { callback() }
                continuation.resume()
            }
        }
        #expect(disposed.withLock { $0 } == [42, 41])
    }

    @Test func failedSoundCreationDoesNotPlayOrDisposeAnInvalidIdentifier() {
        let player = MobileSystemSoundPlayer(
            create: { _ in nil },
            start: { _, _ in Issue.record("Failed creation must not start playback") },
            dispose: { _ in Issue.record("Failed creation has no sound to dispose") })
        player.play(url: URL(fileURLWithPath: "/missing.wav"))
    }
}
