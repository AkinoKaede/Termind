import GhosttyTerminal
import UIKit

/// A workspace owns its native surface even while SwiftUI navigates away from it.
@MainActor
final class MobileTerminalSurface {
    let view = TerminalView(frame: .zero)
}
