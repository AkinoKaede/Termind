// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit

nonisolated

    extension AIModel
{
    /// The input cap can be smaller than the total context window. Do not let
    /// compaction wait for the larger limit after loading models.dev metadata.
    public var compactionContextWindow: Int? {
        [specification.limit.context, specification.limit.input].compactMap { $0 }.filter { $0 > 0 }.min()
    }

    /// Older clients must not mistake newly classified, non-chat models for chat.
    public var legacyKindValue: String {
        switch kind {
        case .speech, .transcription, .realtime, .other: AIModel.Kind.classifier.rawValue
        default: kind.rawValue
        }
    }

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
