import AppKit
import Testing

@testable import Termind

@Suite
@MainActor
struct WindowSidebarTests {
    @Test
    func legacySidebarMaterialStaysWithinTheWindow() {
        let view = NSVisualEffectView()

        LegacySidebarMaterialBackground.configure(view)

        #expect(view.material == .windowBackground)
        #expect(view.blendingMode == .withinWindow)
        #expect(view.state == .followsWindowActiveState)
    }

    @Test
    func allDestinationsExposeNavigatorAndThreeToolSidebars() {
        let window = WindowModel()
        let expected: [WindowSidebarState.Mode] = [.navigation, .assistant, .snippets, .history]

        #expect(window.availableSidebarModes == expected)
        window.selectVault()
        #expect(window.availableSidebarModes == expected)
        window.selectAssistant()
        #expect(window.availableSidebarModes == expected)
    }

    @Test
    func sidebarModeAndVisibilityAreWindowScopedAndSurviveNavigation() {
        let first = WindowModel()
        let second = WindowModel()

        first.sidebarMode = .history
        first.showsSidebar = false
        first.selectAssistant()

        #expect(first.sidebarMode == .history)
        #expect(!first.showsSidebar)
        #expect(second.sidebarMode == .navigation)
        #expect(second.showsSidebar)
    }

    @Test
    func statusBarBelongsOnlyToWorkPanes() {
        #expect(PaneKind.sshSession.showsStatusBar)
        #expect(PaneKind.sftpSession.showsStatusBar)
        #expect(!PaneKind.empty.showsStatusBar)
    }
}
