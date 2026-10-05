import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct SFTPUploadReceiptTests {
    @Test func waitsForAdmissionAndEveryTransferAndPreservesSelectionOrder() {
        var received: [[String]] = []
        let receipt = SFTPUploadReceipt(paths: ["/a", "/folder"]) { received.append($0) }
        receipt.admit()
        receipt.completed(0, state: .completed)
        #expect(received.isEmpty)
        receipt.admit()
        receipt.admit()
        receipt.resolve(1, to: "/folder.2")
        receipt.finishAdmission()
        receipt.completed(1, state: .completed)
        #expect(received.isEmpty)
        receipt.completed(1, state: .completed)
        #expect(received == [["/a", "/folder.2"]])
        receipt.finishAdmission()
        #expect(received.count == 1)
    }

    @Test func excludesFailedCancelledAndSkippedRoots() {
        var received: [[String]] = []
        let receipt = SFTPUploadReceipt(paths: ["/ok", "/failed", "/cancelled", "/skipped"]) {
            received.append($0)
        }
        for _ in 0..<3 { receipt.admit() }
        receipt.resolve(3, to: nil)
        receipt.finishAdmission()
        receipt.completed(2, state: .cancelled)
        receipt.completed(0, state: .completed)
        receipt.completed(1, state: .failed("offline"))
        #expect(received == [["/ok"]])
    }

    @Test func emptyDirectoriesCompleteAfterAdmissionAndCancelledAdmissionNeverDelivers() {
        var received: [[String]] = []
        let empty = SFTPUploadReceipt(paths: ["/empty"]) { received.append($0) }
        #expect(received.isEmpty)
        empty.finishAdmission()
        #expect(received == [["/empty"]])
        let cancelled = SFTPUploadReceipt(paths: ["/cancelled"]) { received.append($0) }
        cancelled.admit()
        cancelled.cancel()
        cancelled.finishAdmission()
        cancelled.completed(0, state: .completed)
        #expect(received == [["/empty"]])
    }
}
