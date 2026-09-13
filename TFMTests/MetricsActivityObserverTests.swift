import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite
@MainActor
struct MetricsActivityObserverTests {
    @Test
    func wakeWaitsForTheLoginSessionBeforeResumingMetrics() {
        let model = makeModel()
        let observer = MetricsActivityObserver()
        observer.start(model)
        defer {
            observer.stop()
            model.shutdown()
        }

        observer.receive(.sessionDidResignActive)
        #expect(model.sleeping)

        observer.receive(.systemWillSleep)
        observer.receive(.systemDidWake)
        #expect(model.sleeping)

        observer.receive(.sessionDidBecomeActive)
        #expect(!model.sleeping)
    }

    @Test
    func systemSleepStillResumesWithoutASessionTransition() {
        let model = makeModel()
        let observer = MetricsActivityObserver()
        observer.start(model)
        defer {
            observer.stop()
            model.shutdown()
        }

        observer.receive(.systemWillSleep)
        #expect(model.sleeping)
        observer.receive(.systemDidWake)
        #expect(!model.sleeping)
    }

    private func makeModel() -> ServerMetricsModel {
        let model = ServerMetricsModel(
            hosts: HostLibraryModel(), preferences: ActivityObserverPreferences(),
            makeSampler: { preconditionFailure("No monitor is configured") }
        )
        model.start()
        return model
    }
}

@MainActor
private final class ActivityObserverPreferences: MetricsConfigurationStoring {
    func load() -> [MetricsSelection] { [] }
    func save(_ selections: [MetricsSelection]) {}
}
