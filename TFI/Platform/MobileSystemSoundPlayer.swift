// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AudioToolbox
import Foundation

nonisolated struct MobileSystemSoundPlayer: Sendable {
    var create: @Sendable (URL) -> SystemSoundID?
    var start: @Sendable (SystemSoundID, @escaping @Sendable () -> Void) -> Void
    var dispose: @Sendable (SystemSoundID) -> Void

    static let live = Self(
        create: { url in
            var sound: SystemSoundID = 0
            guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == kAudioServicesNoError else { return nil }
            return sound
        },
        start: { sound, completion in AudioServicesPlaySystemSoundWithCompletion(sound, completion) },
        dispose: { AudioServicesDisposeSystemSoundID($0) })

    func play(url: URL) {
        guard let sound = create(url) else { return }
        // AudioToolbox invokes completion on its serial queue, not the main actor.
        start(sound) { [dispose] in dispose(sound) }
    }
}
