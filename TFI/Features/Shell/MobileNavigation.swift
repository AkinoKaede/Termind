// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

nonisolated enum MobileDestination: String, CaseIterable, Identifiable {
    case vault, metrics, workspaces, assistant, settings

    var id: Self { self }
}
