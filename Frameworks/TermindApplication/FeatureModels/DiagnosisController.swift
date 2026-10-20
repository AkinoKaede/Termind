// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Observation

@MainActor
public protocol DiagnosticDataReporting: AnyObject {
    func setEnabled(_ enabled: Bool)
}

/// Consent belongs to this installation, never to the synced Settings snapshot.
@MainActor @Observable
public final class DiagnosisController {
    public private(set) var consent: Bool?
    private let defaults: UserDefaults?
    private let reporter: (any DiagnosticDataReporting)?

    public var needsConsent: Bool { defaults != nil && consent == nil }
    public var isEnabled: Bool { consent == true }

    /// An unconfigured controller is inert for previews, screenshots and test hosts.
    public init(defaults: UserDefaults? = nil, reporter: (any DiagnosticDataReporting)? = nil) {
        self.defaults = defaults
        self.reporter = reporter
        consent = defaults?.object(forKey: SettingsKey.diagnosisConsent) as? Bool
        reporter?.setEnabled(consent == true)
    }

    public func setEnabled(_ enabled: Bool) {
        guard consent != enabled else { return }
        defaults?.set(enabled, forKey: SettingsKey.diagnosisConsent)
        consent = enabled
        reporter?.setEnabled(enabled)
    }
}
