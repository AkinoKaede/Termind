// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindDomain

import struct TermindDomain.Host

nonisolated enum MobileSnippetExecutionDecision: Equatable {
    case chooseHosts
    case confirmDestructive([Host.ID])
    case execute([Host.ID])
}

nonisolated enum MobileSnippetOperations {
    static func executionDecision(
        for snippet: Snippet,
        hostIDs: [Host.ID],
        requiresHostSelection: Bool
    ) -> MobileSnippetExecutionDecision {
        if requiresHostSelection || hostIDs.isEmpty { return .chooseHosts }
        if CommandRiskClassifier.assess(snippet.body).requiresSecondConfirmation {
            return .confirmDestructive(hostIDs)
        }
        return .execute(hostIDs)
    }
}
