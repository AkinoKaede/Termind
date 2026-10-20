// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindDomain

@MainActor
public protocol MetricsConfigurationStoring {
    func load() throws -> [MetricsSelection]
    func save(_ selections: [MetricsSelection]) throws
}
