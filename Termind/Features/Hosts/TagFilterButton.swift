import SwiftUI

/// The Hosts page's tag filter: a popover listing every tag in use, each one a
/// toggle, each one removable.
///
/// A popover rather than a `Menu`, for the ⓧ. A menu item is one target with one
/// action, so "filter by this" and "delete this" could not both live on the same
/// row — they would have to become two menus, or a menu of tags and a submenu of
/// the same tags again. The popover is a list, and a list row has room for both.
///
/// Deleting is destructive and the caller confirms it; this view only reports
/// which tag was asked about.
struct TagFilterButton: View {
    let tags: [String]
    @Binding var selection: Set<String>
    /// Called with the tag whose ⓧ was clicked. The caller confirms before
    /// anything is removed — see `HostsPageView`.
    let requestDelete: (String) -> Void

    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing = true
        } label: {
            HStack(spacing: Metrics.Space.xs) {
                Image(systemName: "tag")
                if !selection.isEmpty {
                    Text(selection.count, format: .number)
                        .monospacedDigit()
                }
            }
            .contentShape(.rect)
        }
        // Tinted while filtering, because a list showing a subset of the
        // machines has to say so somewhere the eye lands.
        .buttonStyle(.bordered)
        .tint(selection.isEmpty ? nil : .accentColor)
        .disabled(tags.isEmpty)
        .help(
            Text(
                selection.isEmpty
                    ? "Filter by tag"
                    : selection.count == 1
                        ? "Filtering by 1 tag" : "Filtering by \(selection.count) tags"
            )
        )
        .accessibilityLabel(Text("Filter by tag"))
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            popover
        }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Filter by Tag")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.Space.l)
                .padding(.top, Metrics.Space.l)
                .padding(.bottom, Metrics.Space.s)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tags, id: \.self) { tag in
                        TagFilterRow(
                            tag: tag,
                            isOn: selection.contains(tag),
                            toggle: { toggle(tag) },
                            delete: { requestDelete(tag) }
                        )
                    }
                }
                .padding(.horizontal, Metrics.Space.s)
            }
            .frame(maxHeight: Metrics.TagFilter.maxListHeight)

            if !selection.isEmpty {
                Divider()
                Button("Clear Filter") { selection.removeAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .padding(Metrics.Space.l)
            }
        }
        .frame(width: Metrics.TagFilter.width)
        // Several tags are usually picked in one visit, so the popover stays up
        // between toggles and the animation is what confirms each one landed.
        .animation(Motion.tabSwitch, value: selection)
    }

    private func toggle(_ tag: String) {
        if selection.contains(tag) {
            selection.remove(tag)
        } else {
            selection.insert(tag)
        }
    }
}

// MARK: - Row

private struct TagFilterRow: View {
    let tag: String
    let isOn: Bool
    let toggle: () -> Void
    let delete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            // A reserved slot rather than a conditional, so the names stay in
            // one column whether or not anything is ticked.
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
                .opacity(isOn ? 1 : 0)

            Text(tag)
                .lineLimit(1)

            Spacer(minLength: Metrics.Space.s)

            // Only under the pointer: a row of delete buttons reads as a list of
            // things to delete, and this is a list of things to filter by.
            Button(action: delete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .help(Text("Delete tag “\(tag)”"))
            .accessibilityLabel(Text("Delete tag \(tag)"))
        }
        .padding(.horizontal, Metrics.Space.m)
        .padding(.vertical, Metrics.Space.s)
        .background(
            Highlight.fill(isSelected: false, isHovering: isHovering),
            in: .rect(cornerRadius: Metrics.Radius.small)
        )
        .contentShape(.rect(cornerRadius: Metrics.Radius.small))
        .onTapGesture(perform: toggle)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    @Previewable @State var selection: Set<String> = ["prod"]

    PageToolbar(query: .constant(""), prompt: "Filter hosts") {
        TagFilterButton(
            tags: HostStore.demo().hostTags,
            selection: $selection,
            requestDelete: { _ in }
        )
    } actions: {
        Button("New Host") {}
    }
    .frame(width: 640)
}
