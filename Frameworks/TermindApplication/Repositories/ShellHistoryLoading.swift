// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindDomain

public nonisolated protocol ShellHistoryLoading: Sendable {
    func load(source: ShellHistorySource?) async throws -> [ShellHistoryRecord]
}
