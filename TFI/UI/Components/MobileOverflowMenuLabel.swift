import SwiftUI

/// Keeps every mobile overflow menu on the same symbol while preserving a contextual accessible name.
struct MobileOverflowMenuLabel: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Label(title, systemImage: "ellipsis")
            .labelStyle(.iconOnly)
    }
}
