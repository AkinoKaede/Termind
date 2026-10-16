import GhosttyTerminal
import SwiftUI

/// Request focus on entry or readiness changes, not ordinary view updates.
struct MobileTerminalInitialFocus: ViewModifier {
    let terminal: TerminalViewState
    let isReady: Bool
    var blocksInput = false

    func body(content: Content) -> some View {
        content
            .onAppear { requestFocusIfReady() }
            .onChange(of: isReady) { _, _ in requestFocusIfReady() }
            .onChange(of: blocksInput) { _, _ in requestFocusIfReady() }
    }

    private func requestFocusIfReady() {
        terminal.attachedPlatformView?.isUserInteractionEnabled = !blocksInput
        if blocksInput {
            terminal.attachedPlatformView?.resignFirstResponder()
            return
        }
        guard isReady else { return }
        terminal.requestFocus()
    }
}
