import GhosttyTerminal
import SwiftUI

/// Follows Ghostty's resolved theme and program background without reconfiguring the surface.
public struct TerminalBackground: View {
    @ObservedObject private var state: TerminalViewState

    public init(state: TerminalViewState) {
        self.state = state
    }

    public var body: some View {
        Color(state.backgroundColor)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
