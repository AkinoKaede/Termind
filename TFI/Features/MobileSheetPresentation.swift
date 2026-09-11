import SwiftUI
import UIKit

/// iPad forms use the system's centered presentation. Detents are reserved for iPhone trays.
private struct MobileSheetPresentation: ViewModifier {
    var compact: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.presentationSizing(.form)
                .presentationDragIndicator(.hidden)
        } else {
            content.presentationDetents(compact && !typeSize.isAccessibilitySize ? [.medium, .large] : [.large])
                .presentationDragIndicator(.visible)
        }
    }
}

extension View {
    func mobileSheetPresentation(compact: Bool = false) -> some View {
        modifier(MobileSheetPresentation(compact: compact))
    }
}
