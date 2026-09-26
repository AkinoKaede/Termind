import Foundation
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileStartupViewTests {
    private enum StartupFailure: Error { case unavailableStore }

    @Test func successfulSceneContentCanBeCreatedOffMainThread() async throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }
        let makeContent = MobileStartupView.sceneContent(for: .success(app))

        let content = await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            return makeContent()
        }.value

        #expect(try content.startup.get() === app)
    }

    @Test func failedSceneContentCanBeCreatedOffMainThread() async {
        let makeContent = MobileStartupView.sceneContent(for: .failure(StartupFailure.unavailableStore))

        let content = await Task.detached {
            dispatchPrecondition(condition: .notOnQueue(.main))
            return makeContent()
        }.value

        guard case .failure(let error) = content.startup else {
            Issue.record("Failed startup must remain a failure when creating scene content")
            return
        }
        #expect(error as? StartupFailure == .unavailableStore)
    }
}
