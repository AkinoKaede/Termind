// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

/// A saved Host's override of the global terminal preference.
public nonisolated enum HostShellIntegrationMode: String, Codable, CaseIterable, Sendable {
    case followGlobalSettings
    case enabled
    case disabled

    public func isEnabled(globalSetting: Bool) -> Bool {
        switch self {
        case .followGlobalSettings: globalSetting
        case .enabled: true
        case .disabled: false
        }
    }
}
