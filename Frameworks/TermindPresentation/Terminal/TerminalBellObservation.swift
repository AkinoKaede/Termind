// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Combine
import GhosttyTerminal

/// Observe the retained session, not its transient SwiftUI presentation.
@MainActor
public final class TerminalBellObservation {
    private var observation: AnyCancellable?

    public init(state: TerminalViewState, ring: @escaping @MainActor () -> Void) {
        observation = state.$bellCount.removeDuplicates().dropFirst().sink { _ in ring() }
    }
}
