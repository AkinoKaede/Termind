import SwiftUI

/// The line of small print under a manager page's table. Used for the things a
/// user needs told once — where private keys actually live, when a tunnel is
/// open — rather than in a settings pane they will never open.
struct PageFootnote<Actions: View>: View {
    let text: LocalizedStringKey
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Metrics.Space.m)
            actions
        }
        .controlSize(.small)
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.m)
        .termindGlassBar()
    }
}
