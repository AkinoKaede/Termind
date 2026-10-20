// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Dispatch
import Logging
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct SSHConnectionWorkerLifecycleTests {
    @Test func lastReferenceCanBeReleasedOnTheConnectionQueue() async {
        let queue = DispatchQueue(label: "termind.tests.ssh.connection")
        await withCheckedContinuation { continuation in
            queue.async {
                var worker: SSHConnectionWorker? = SSHConnectionWorker(
                    logger: Logger(label: "termind.tests"), maxSessionsPolicy: SSHMaxSessionsPolicy(), queue: queue)
                weak let released = worker
                #expect(released != nil)
                worker = nil
                #expect(released == nil)
                continuation.resume()
            }
        }
    }

    @Test func lastReferenceCanBeReleasedOutsideTheConnectionQueue() {
        let queue = DispatchQueue(label: "termind.tests.ssh.connection")
        dispatchPrecondition(condition: .notOnQueue(queue))
        var worker: SSHConnectionWorker? = SSHConnectionWorker(
            logger: Logger(label: "termind.tests"), maxSessionsPolicy: SSHMaxSessionsPolicy(), queue: queue)
        weak let released = worker
        #expect(released != nil)
        worker = nil
        #expect(released == nil)
    }
}
