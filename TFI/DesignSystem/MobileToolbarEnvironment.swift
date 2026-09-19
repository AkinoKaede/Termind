import SwiftUI

struct MobileToolbarLayout: Equatable {
    var isTopBar = false
    var verticalEdge: HorizontalEdge?

    var isVertical: Bool { verticalEdge != nil }
    var usesIconSwitcher: Bool { isTopBar || isVertical }
    var showsWorkspaceTabs: Bool { isTopBar || isVertical }
}

extension EnvironmentValues {
    @Entry var mobileToolbarLayout = MobileToolbarLayout()
}

/// Read inside a Tab's content, outside the detail's visibility preferences.
private struct MobileToolbarEnvironment: ViewModifier {
    @Environment(\.tabBarPlacement) private var placement

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(MobileVerticalToolbarEnvironment(isTopBar: placement == .topBar))
        } else {
            content.environment(
                \.mobileToolbarLayout,
                MobileToolbarLayout(isTopBar: placement == .topBar))
        }
    }
}

@available(iOS 27.1, *)
private struct MobileVerticalToolbarEnvironment: ViewModifier {
    let isTopBar: Bool
    @Environment(\.toolbarVerticalEdge) private var edge

    func body(content: Content) -> some View {
        content.environment(
            \.mobileToolbarLayout,
            MobileToolbarLayout(isTopBar: isTopBar, verticalEdge: edge))
    }
}

extension View {
    func mobileToolbarEnvironment() -> some View {
        modifier(MobileToolbarEnvironment())
    }
}
