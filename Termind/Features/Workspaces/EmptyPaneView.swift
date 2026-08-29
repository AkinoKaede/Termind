import SwiftUI

/// A split that has been carved but not filled.
///
/// Split makes one of these instead of opening a connection. Choosing a layout
/// and choosing a machine are two decisions, and only one of them was asked for
/// — the old behaviour connected to a host on your behalf as a side effect of
/// pressing ⌘D, which is how a keystroke meant for the window ends up on a
/// server.
///
/// What fills it has to be something already open, so the slot advertises the
/// one gesture that works: drag a workspace in.
///
/// Purely the prompt. The drop belongs to `PaneView`, which handles every pane
/// now rather than only the empty ones — two nested drop targets over the same
/// rectangle fight for the drag, and the outer one already knows this pane is
/// empty and should replace rather than split. Closing belongs to `PaneView`'s
/// header too, for the same reason: one × per pane, in the same place on all of
/// them.
struct EmptyPaneView: View {
    var body: some View {
        VStack(spacing: Metrics.Space.l) {
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)

            VStack(spacing: Metrics.Space.xs) {
                Text("Empty Pane")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Drag an SSH session, SFTP session, or chat here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TermindColor.windowSurface)
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.Radius.large)
                .strokeBorder(
                    Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
                .padding(Metrics.Space.m)
                .allowsHitTesting(false)
        }
    }
}
