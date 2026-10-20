// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit

nonisolated

    extension AIModel
{
    public var withoutReasoningOverride: AIModel {
        var copy = self
        copy.reasoningProfile = nil
        return copy
    }

    /// Updates one reasoning level while preserving at least one supported
    /// effort. Returns false when disabling the final supported effort is
    /// rejected.
    public mutating func setReasoningEffort(_ effort: ReasoningEffort, isSupported: Bool) -> Bool {
        let supportedCount = reasoningProfile?.levels.values.filter(\.isSupported).count ?? 0
        guard isSupported || supportedCount > 1 else { return false }
        updateReasoningMapping(effort) { $0.isSupported = isSupported }
        return true
    }

    public mutating func setReasoningWireValue(_ value: String?, for effort: ReasoningEffort) {
        updateReasoningMapping(effort) { $0.wireValue = value }
    }

    private mutating func updateReasoningMapping(
        _ effort: ReasoningEffort,
        update: (inout ReasoningLevelMapping) -> Void
    ) {
        var profile = reasoningProfile ?? ReasoningProfile()
        var mapping = profile.mapping(for: effort)
        update(&mapping)
        profile.levels[effort] = mapping
        reasoningProfile = profile
    }
}
