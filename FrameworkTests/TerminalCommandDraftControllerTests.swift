import Foundation
import TermindApplication
import Testing

@Suite @MainActor
struct TerminalCommandDraftControllerTests {
    @Test
    func readsOneDraftAndRejectsConcurrentRequests() async throws {
        let controller = TerminalCommandDraftController()
        var writes: [Data] = []
        let first = Task {
            try await controller.read(isAvailable: true) { data in
                writes.append(data)
            }
        }
        while !controller.hasPendingRequest { await Task.yield() }

        await #expect(throws: TerminalDraftError.self) {
            try await controller.read(isAvailable: true) { _ in }
        }
        controller.receive("list files")

        #expect(try await first.value == "list files")
        #expect(writes == [TerminalCommandDraftController.requestPayload])
    }

    @Test
    func replacementUsesBracketedPasteWithoutSubmitting() {
        let payload = TerminalCommandDraftController().replacementPayload(for: "ls -la")

        #expect(payload == Data("\u{1B}[777;2~\u{1B}[200~ls -la\u{1B}[201~".utf8))
        #expect(!payload.contains(0x0A))
        #expect(!payload.contains(0x0D))
    }

    @Test
    func cancellationResumesThePendingReader() async {
        let controller = TerminalCommandDraftController()
        let read = Task {
            try await controller.read(isAvailable: true) { _ in }
        }
        while !controller.hasPendingRequest { await Task.yield() }

        controller.cancel(CancellationError())

        await #expect(throws: CancellationError.self) {
            try await read.value
        }
        #expect(!controller.hasPendingRequest)
    }
}
