import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import Testing

@testable import TermindIOS
@testable import TermindPresentation

@Suite @MainActor
struct MobileMetricsHostAccessTests {
    @Test func lockedSelectionsPersistWithoutSamplersAndResumeAfterUpgrade() async throws {
        let identity = Identity(name: "Metrics", username: "root", credentialRef: "metrics-password")
        let secrets = InMemorySecretStore()
        try secrets.setString("test-only", for: identity.credentialRef, storage: identity.passwordStorage)
        let hosts = (0..<4).map {
            TermindDomain.Host(
                name: "Host \($0)", host: "host.invalid", identityID: identity.id,
                createdAt: Date(timeIntervalSince1970: Double($0)))
        }
        let library = HostLibraryModel(hosts: hosts, identities: [identity], secrets: secrets)
        library.hostAccess.entitlement = .free
        let preferences = MobileLockedMetricsPreferences()
        let recorder = MobileAdmissionSamplerRecorder()
        let metrics = MobileMetricsModel(
            preferences: preferences, hosts: library,
            services: MobileMetricsServices(makeSampler: { recorder.makeSampler() }))
        defer { metrics.core.shutdown() }
        let added = metrics.add(hosts[3].id)
        #expect(added)
        let server = try #require(metrics.servers.first)
        metrics.core.reconcile()
        #expect(server.isHostLocked)
        #expect(preferences.values.map(\.id) == [hosts[3].id])
        #expect(metrics.selections.map(\.id) == [hosts[3].id])
        #expect(recorder.count == 0)

        library.hostAccess.entitlement = .purchased(.purchased)
        metrics.core.reconcile()
        for _ in 0..<200 where recorder.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!server.isHostLocked)
        #expect(recorder.count == 1)
        #expect(preferences.values.map(\.id) == [hosts[3].id])
    }

    @Test func failedAccessUsesErrorIndicatorRatherThanAnIndefiniteSpinner() {
        let server = ServerMetric(selection: MetricsSelection(id: UUID()), name: "Host")
        server.hostAccessError = .entitlementVerificationFailed
        #expect(MetricsInstrumentBody(server: server, sleeping: false).connectionIndicator == .attention)
        server.hostAccessError = .verifyingEntitlement
        server.isConnecting = true
        #expect(MetricsInstrumentBody(server: server, sleeping: false).connectionIndicator == .progress)
    }

    @Test func hostQuotaDoesNotProduceAFallbackSaveAlert() {
        let error: any Error = HostAccessError.hostLimit
        #expect(HostAccessError.presentationDescription(of: error) == nil)
    }

    @Test func erasedHostAccessErrorsUseTheLocalizedPresentationMessage() {
        let error: any Error = HostAccessError.entitlementVerificationFailed
        #expect(error.localizedDescription == String(localized: AppStrings.Pro.accessVerificationFailed))
    }

    @Test func lockedCardActivationOpensPaywallInsteadOfDetails() throws {
        let free = ProAccessController.testing(status: .free)
        var dependencies = MobileAppDependencies.testing()
        dependencies.proAccess = free
        let app = try MobileAppModel(dependencies: dependencies)
        defer { app.metrics.core.shutdown() }
        let server = ServerMetric(selection: MetricsSelection(id: UUID()), name: "Locked")
        server.point = MetricsPoint(date: .now, cpu: 50)
        server.hostAccessError = .lockedHost(server.id)
        var inspected = false
        app.activateMetrics(server) { inspected = true }
        #expect(free.isPaywallPresented)
        #expect(!inspected)
        #expect(server.point != nil)
        free.isPaywallPresented = false
        server.hostAccessError = .entitlementVerificationFailed
        app.activateMetrics(server) { inspected = true }
        #expect(!free.isPaywallPresented)
        #expect(inspected)
    }
}

@MainActor private final class MobileLockedMetricsPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection] = []
    func load() -> [MetricsSelection] { values }
    func save(_ selections: [MetricsSelection]) { values = selections }
}

private nonisolated final class MobileAdmissionSamplerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var creations = 0
    var count: Int { lock.withLock { creations } }
    func makeSampler() -> any MetricsSampling {
        lock.withLock { creations += 1 }
        return MobileAdmissionMetricsSampler()
    }
}

private actor MobileAdmissionMetricsSampler: MetricsSampling {
    func connect(_ configuration: SSHConnectionConfiguration) async throws { throw CancellationError() }
    func sample() async throws -> MetricsSample { throw CancellationError() }
    func gpu() async throws -> NvidiaSnapshot? { nil }
    func disconnect() async {}
}
