import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import Testing

@testable import TermindIOS
@testable import TermindPresentation

@Suite @MainActor
struct MobileMetricsHostAccessTests {
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
