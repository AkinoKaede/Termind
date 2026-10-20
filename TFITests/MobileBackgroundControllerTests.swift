// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileBackgroundControllerTests {
    @Test func expirationRunsSynchronouslyAndEndsEachLeaseExactlyOnce() throws {
        let first = UIBackgroundTaskIdentifier(rawValue: 1)
        let second = UIBackgroundTaskIdentifier(rawValue: 2)
        let platform = MobileBackgroundTaskPlatformSpy(tasks: [first, second])
        var events: [String] = []
        platform.didEnd = { _ in events.append("end") }
        let controller = MobileBackgroundController(platform: platform)

        controller.begin { events.append("expire-first") }
        let stale = try #require(platform.expirations.first)
        controller.finish()
        stale()
        stale()

        controller.begin { events.append("expire-second") }
        let current = try #require(platform.expirations.last)
        current()
        current()
        controller.finish()

        #expect(events == ["end", "expire-second", "end"])
        #expect(platform.ended == [first, second])
    }

    @Test func synchronousExpirationDuringBeginRetiresReturnedTaskWithoutOverwritingReplacement() throws {
        let expired = UIBackgroundTaskIdentifier(rawValue: 1)
        let replacement = UIBackgroundTaskIdentifier(rawValue: 2)
        let platform = MobileBackgroundTaskPlatformSpy(tasks: [expired, replacement])
        var expirationCount = 0
        var replacementExpirationCount = 0
        var controller: MobileBackgroundController!
        platform.expireSynchronouslyOnNextBegin = true
        controller = MobileBackgroundController(platform: platform)

        controller.begin {
            expirationCount += 1
            controller.begin { replacementExpirationCount += 1 }
        }

        #expect(expirationCount == 1)
        #expect(replacementExpirationCount == 0)
        #expect(platform.ended == [expired])
        let replacementExpiration = try #require(platform.expirations.last)
        replacementExpiration()
        #expect(replacementExpirationCount == 1)
        #expect(platform.ended == [expired, replacement])
    }

    @Test func invalidBeginExpiresOnceWithoutEndingAnInvalidTask() {
        var expirationCount = 0
        let platform = MobileBackgroundTaskPlatformSpy(tasks: [.invalid])
        let controller = MobileBackgroundController(platform: platform)

        controller.begin { expirationCount += 1 }
        controller.finish()

        #expect(expirationCount == 1)
        #expect(platform.ended.isEmpty)
    }
}

@MainActor
private final class MobileBackgroundTaskPlatformSpy: MobileBackgroundTaskPlatform {
    var expirations: [@MainActor () -> Void] = []
    var ended: [UIBackgroundTaskIdentifier] = []
    var expireSynchronouslyOnNextBegin = false
    var didEnd: ((UIBackgroundTaskIdentifier) -> Void)?
    private var tasks: [UIBackgroundTaskIdentifier]

    init(tasks: [UIBackgroundTaskIdentifier]) {
        self.tasks = tasks
    }

    func begin(expiration: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        let task = tasks.removeFirst()
        expirations.append(expiration)
        if expireSynchronouslyOnNextBegin {
            expireSynchronouslyOnNextBegin = false
            expiration()
        }
        return task
    }

    func end(_ task: UIBackgroundTaskIdentifier) {
        ended.append(task)
        didEnd?(task)
    }
}
