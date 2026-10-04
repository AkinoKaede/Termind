import Dispatch
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct SSHPTYChannelWorkerLifecycleTests {
    @Test func lastReferenceCanBeReleasedOnThePTYQueue() async {
        let queue = DispatchQueue(label: "termind.tests.pty.lifecycle")
        await withCheckedContinuation { continuation in
            queue.async {
                var worker: SSHPTYChannelWorker? = SSHPTYChannelWorker(
                    output: { _ in }, exit: { _ in }, shellIntegrationHandler: { _ in }, queue: queue)
                weak let released = worker
                worker = nil
                #expect(released == nil)
                continuation.resume()
            }
        }
    }

    @Test func lastReferenceCanBeReleasedOutsideThePTYQueue() {
        let queue = DispatchQueue(label: "termind.tests.pty.lifecycle")
        dispatchPrecondition(condition: .notOnQueue(queue))
        var worker: SSHPTYChannelWorker? = SSHPTYChannelWorker(
            output: { _ in }, exit: { _ in }, shellIntegrationHandler: { _ in }, queue: queue)
        weak let released = worker
        worker = nil
        #expect(released == nil)
    }
}
