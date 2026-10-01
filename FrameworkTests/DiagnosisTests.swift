import Foundation
import TermindApplication
import TermindInfrastructure
import Testing

@Suite @MainActor
struct DiagnosisTests {
    @Test
    func firstLaunchWaitsForAnExplicitChoice() async throws {
        try await withDefaults { defaults in
            let reporter = RecordingReporter()
            let controller = DiagnosisController(defaults: defaults, reporter: reporter)
            #expect(controller.needsConsent)
            #expect(!controller.isEnabled)
            #expect(controller.consent == nil)
            #expect(defaults.object(forKey: SettingsKey.diagnosisConsent) == nil)
            #expect(reporter.values == [false])
        }
    }

    @Test(arguments: [false, true])
    func bothChoicesPersistWithoutAskingAgain(enabled: Bool) async throws {
        try await withDefaults { defaults in
            let reporter = RecordingReporter()
            let controller = DiagnosisController(defaults: defaults, reporter: reporter)
            controller.setEnabled(enabled)
            controller.setEnabled(enabled)
            #expect(!controller.needsConsent)
            #expect(controller.isEnabled == enabled)
            #expect(reporter.values == [false, enabled])
            let nextLaunch = DiagnosisController(defaults: defaults, reporter: reporter)
            #expect(!nextLaunch.needsConsent)
            #expect(nextLaunch.consent == enabled)
            #expect(reporter.values == [false, enabled, enabled])
        }
    }

    @Test
    func revocationPersistsBeforeApplyingItToTheSDK() async throws {
        try await withDefaults { defaults in
            defaults.set(true, forKey: "diagnostics.crashReportingConsent")
            let reporter = RecordingReporter()
            let controller = DiagnosisController(defaults: defaults, reporter: reporter)
            reporter.didChange = { enabled in
                #expect(defaults.object(forKey: SettingsKey.diagnosisConsent) as? Bool == enabled)
            }
            controller.setEnabled(false)
            #expect(reporter.values == [true, false])
            #expect(!DiagnosisController(defaults: defaults).needsConsent)
        }
    }

    @Test
    func testAndPreviewControllersDoNotPresentConsent() {
        #expect(!DiagnosisController().needsConsent)
        #expect(!DiagnosisController().isEnabled)
    }

    @Test
    func unknownAndDeclinedConsentNeverInitializeFirebase() async throws {
        try await withDefaults { defaults in
            var initializations = 0
            let reporter = FirebaseDiagnosticDataReporter(defaults: defaults) {
                initializations += 1
                return nil
            }
            let controller = DiagnosisController(defaults: defaults, reporter: reporter)
            controller.setEnabled(false)
            #expect(initializations == 0)
            controller.setEnabled(true)
            #expect(initializations == 1)
            // A missing developer configuration does not lose the user's choice or block startup.
            #expect(controller.isEnabled && !controller.needsConsent)
        }
    }

    @Test
    func optedInLaunchSendsPendingDiagnosticDataOnce() async throws {
        try await withDefaults { defaults in
            let client = DeferredDiagnosticDataClient()
            let reporter = FirebaseDiagnosticDataReporter(defaults: defaults) { client }
            reporter.setEnabled(true)
            await client.waitForCheck()
            client.finishCheck(hasData: true)
            await client.waitForAction()
            reporter.setEnabled(true)
            #expect(client.sends == 1)
            #expect(client.deletes == 0)
            #expect(client.checks == 1)
        }
    }

    @Test
    func consentRevokedDuringSDKCheckDeletesInsteadOfUploading() async throws {
        try await withDefaults { defaults in
            let client = DeferredDiagnosticDataClient()
            let reporter = FirebaseDiagnosticDataReporter(defaults: defaults) { client }
            reporter.setEnabled(true)
            await client.waitForCheck()
            reporter.setEnabled(false)
            client.finishCheck(hasData: true)
            await client.waitForAction()
            #expect(client.sends == 0)
            #expect(client.deletes == 1)
        }
    }

    @Test
    func optingBackInDiscardsDiagnosticDataFromBeforeConsentWasRestored() async throws {
        try await withDefaults { defaults in
            let previousLaunch = FirebaseDiagnosticDataReporter(defaults: defaults) { nil }
            previousLaunch.setEnabled(false)
            #expect(defaults.bool(forKey: "diagnostics.discardPendingCrashReports"))
            let client = DeferredDiagnosticDataClient()
            let reporter = FirebaseDiagnosticDataReporter(defaults: defaults) { client }
            reporter.setEnabled(true)
            await client.waitForCheck()
            client.finishCheck(hasData: true)
            await client.waitForAction()
            #expect(client.sends == 0 && client.deletes == 1)

            let nextClient = DeferredDiagnosticDataClient()
            let nextLaunch = FirebaseDiagnosticDataReporter(defaults: defaults) { nextClient }
            nextLaunch.setEnabled(true)
            await nextClient.waitForCheck()
            nextClient.finishCheck(hasData: true)
            await nextClient.waitForAction()
            #expect(nextClient.sends == 1 && nextClient.deletes == 0)
        }
    }

    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async throws {
        let domain = "DiagnosisTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try await body(defaults)
    }
}

@MainActor
private final class RecordingReporter: DiagnosticDataReporting {
    var values: [Bool] = []
    var didChange: ((Bool) -> Void)?

    func setEnabled(_ enabled: Bool) {
        values.append(enabled)
        didChange?(enabled)
    }
}

@MainActor
private final class DeferredDiagnosticDataClient: DiagnosticDataClient {
    var sends = 0
    var deletes = 0
    var checks = 0
    private var pendingCheck: CheckedContinuation<Bool, Never>?
    private var checkStarted: CheckedContinuation<Void, Never>?
    private var actionFinished: CheckedContinuation<Void, Never>?

    func hasUnsentDiagnosticData() async -> Bool {
        checks += 1
        return await withCheckedContinuation { continuation in
            pendingCheck = continuation
            checkStarted?.resume()
            checkStarted = nil
        }
    }

    func waitForCheck() async {
        if pendingCheck != nil { return }
        await withCheckedContinuation { checkStarted = $0 }
    }

    func finishCheck(hasData: Bool) {
        pendingCheck?.resume(returning: hasData)
        pendingCheck = nil
    }

    func sendUnsentDiagnosticData() {
        sends += 1
        actionFinished?.resume()
        actionFinished = nil
    }

    func deleteUnsentDiagnosticData() {
        deletes += 1
        actionFinished?.resume()
        actionFinished = nil
    }

    func waitForAction() async {
        if sends + deletes > 0 { return }
        await withCheckedContinuation { actionFinished = $0 }
    }
}
