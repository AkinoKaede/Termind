// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication

/// Host-supplied behavior for a tool family. The renderer never resolves executable
/// projections from protocol names; the application's trusted catalog does that.
nonisolated public struct AgentToolPresentationProfile: Sendable {
    public struct Operation: Sendable {
        public var action: AgentToolDescriptor.Presentation.ActionKind
        public var activity: String
        public var batchActivity: String
        public var isArgument: Bool

        public init(
            action: AgentToolDescriptor.Presentation.ActionKind, activity: String,
            batchActivity: String? = nil, isArgument: Bool = false
        ) {
            self.action = action
            self.activity = activity
            self.batchActivity = batchActivity ?? activity
            self.isArgument = isArgument
        }
    }

    /// Suppression is distinct from fallback so private results cannot accidentally
    /// reach the generic JSON or error renderer.
    public enum Detail: Sendable {
        case useDefault
        case content(AgentToolDetail)
        case hidden
    }

    public var summary: @Sendable (AgentToolCard, Locale) -> String? = { _, _ in nil }
    public var batchSummary: @Sendable ([AgentToolCard], Locale) -> String? = { _, _ in nil }
    /// Override the noun phrase without bypassing lifecycle phases or the target.
    public var activity: @Sendable (AgentToolCard, Locale) -> String? = { _, _ in nil }
    public var operation: @Sendable (AgentToolCard, Locale, Bool) -> Operation? = { _, _, _ in nil }
    public var batchOperation: @Sendable ([AgentToolCard], Locale) -> Operation? = { _, _ in nil }
    public var phaseSummary:
        @Sendable (AgentToolDescriptor.Presentation.PhaseKind, String, String?, Locale) -> String? = { _, _, _, _ in nil
        }
    public var detail: @Sendable (AgentToolCard, AgentToolDetailPresenter?, Locale) -> Detail = { _, _, _ in .useDefault
    }
    public var approvalItems: @Sendable (AgentToolCard, [String: AgentJSONValue], Locale) -> [AgentToolDetail.Item]? = {
        _, _, _ in nil
    }
    public var title: @Sendable (String) -> String = { $0 }
    public var requiresArgumentProjection = false
    public var hidesTruncationNotice = false
    public var preservesUnprojectedJSON = false
    public var usesSummaryForSingleCompletedBatch = false
    public var omitsMissingArgumentActivity = false

    public init() {}
}
