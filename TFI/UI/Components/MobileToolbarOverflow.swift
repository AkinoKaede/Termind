import SwiftUI
import TermindPresentation

/// Shares actions between the system overflow and the pre-iOS 27 menu.
struct MobileToolbarOverflow<Content: View>: ToolbarContent {
    var title: LocalizedStringResource = AppStrings.Common.more
    var placement: ToolbarItemPlacement = .primaryAction
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        if #available(iOS 27.0, *) {
            ToolbarOverflowMenu { content() }
        } else {
            ToolbarItem(placement: placement) {
                Menu {
                    content()
                } label: {
                    Label(title, systemImage: "ellipsis")
                }
                .labelStyle(.iconOnly)
                .menuOrder(.fixed)
            }
        }
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func mobileProminentAction() -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(.high)
        } else {
            self
        }
    }
}
