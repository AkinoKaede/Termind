// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import FirebaseCore
import FirebaseCrashlytics
import Foundation
import TermindApplication

/// A narrow SDK seam keeps consent and delayed report delivery testable without Firebase traffic.
@MainActor
public protocol DiagnosticDataClient: AnyObject {
    func hasUnsentDiagnosticData() async -> Bool
    func sendUnsentDiagnosticData()
    func deleteUnsentDiagnosticData()
}

@MainActor
public final class FirebaseDiagnosticDataReporter: DiagnosticDataReporting {
    // Preserve the discard marker across terminology changes, just like consent.
    private static let discardKey = "diagnostics.discardPendingCrashReports"
    private let defaults: UserDefaults
    private let makeClient: () -> (any DiagnosticDataClient)?
    private var client: (any DiagnosticDataClient)?
    private var isEnabled = false

    public init(defaults: UserDefaults, makeClient: @escaping () -> (any DiagnosticDataClient)?) {
        self.defaults = defaults
        self.makeClient = makeClient
    }

    public static func live(defaults: UserDefaults = .standard, bundle: Bundle = .main)
        -> FirebaseDiagnosticDataReporter
    {
        FirebaseDiagnosticDataReporter(defaults: defaults) {
            // No Firebase app, installation registration or crash handler before consent.
            guard let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist"),
                let options = FirebaseOptions(contentsOfFile: path),
                options.bundleID == bundle.bundleIdentifier
            else { return nil }
            if FirebaseApp.app() == nil {
                FirebaseApp.configure(options: options)
            }
            FirebaseApp.app()?.isDataCollectionDefaultEnabled = false
            let crashlytics = Crashlytics.crashlytics()
            // Never persist `true`: automatic startup upload would bypass a later revocation.
            crashlytics.setCrashlyticsCollectionEnabled(false)
            return FirebaseDiagnosticDataClient(crashlytics: crashlytics)
        }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        guard enabled else {
            // A crash after opting out must not be uploaded if consent is later granted again.
            defaults.set(true, forKey: Self.discardKey)
            return
        }
        guard client == nil, let client = makeClient() else { return }
        self.client = client
        Task { [weak self] in
            let hasData = await client.hasUnsentDiagnosticData()
            guard let self else { return }
            // The user may revoke consent while the SDK checks the previous run's diagnostic data.
            if !isEnabled || defaults.bool(forKey: Self.discardKey) {
                client.deleteUnsentDiagnosticData()
                if isEnabled { defaults.removeObject(forKey: Self.discardKey) }
            } else if hasData {
                client.sendUnsentDiagnosticData()
            }
        }
    }
}

@MainActor
private final class FirebaseDiagnosticDataClient: DiagnosticDataClient {
    private let crashlytics: Crashlytics

    init(crashlytics: Crashlytics) {
        self.crashlytics = crashlytics
    }

    func hasUnsentDiagnosticData() async -> Bool {
        await crashlytics.checkForUnsentReports()
    }

    func sendUnsentDiagnosticData() { crashlytics.sendUnsentReports() }
    func deleteUnsentDiagnosticData() { crashlytics.deleteUnsentReports() }
}
