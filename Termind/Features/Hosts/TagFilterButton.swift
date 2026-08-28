import AppKit
import ListViewKit
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

            TagFilterNativeList(items: listItems) { item in
                TagFilterRow(
                    tag: item.tag,
                    isOn: item.isOn,
                    toggle: { toggle(item.tag) },
                    delete: { requestDelete(item.tag) }
                )
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

    private var listItems: [TagFilterListItem] {
        tags.map { TagFilterListItem(tag: $0, isOn: selection.contains($0)) }
    }

    private func toggle(_ tag: String) {
        if selection.contains(tag) {
            selection.remove(tag)
        } else {
            selection.insert(tag)
        }
    }
}

nonisolated private struct TagFilterListItem: Identifiable, Hashable, Sendable {
    let tag: String
    let isOn: Bool
    var id: String { tag }
}

private struct TagFilterNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<TagFilterListItem>
    typealias Renderer = @MainActor (TagFilterListItem) -> AnyView
    let items: [TagFilterListItem]
    let renderer: Renderer
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [TagFilterListItem],
        @ViewBuilder renderer: @escaping @MainActor (TagFilterListItem) -> some View
    ) {
        self.items = items
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSViewType { context.coordinator.makeListView() }
    func updateNSView(_ listView: NSViewType, context: Context) {
        context.coordinator.update(
            listView: listView, items: items, renderer: renderer,
            locale: locale, colorScheme: colorScheme
        )
    }

    @MainActor
    final class Coordinator {
        private var renderer: Renderer?
        private var locale = Locale.current
        private var colorScheme = ColorScheme.light
        private var content: [TagFilterListItem] = []

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.topInset = Metrics.Space.xs
            listView.bottomInset = Metrics.Space.s
            listView.estimatedRowHeight = 34
            listView.rows {
                ListRow(TagFilterHostingRow.self)
                    .height { _, _ in 34 }
                    .configure { [weak self] row, item, _ in self?.configure(row, item: item) }
            }
            return listView
        }

        func update(
            listView: NSViewType, items: [TagFilterListItem], renderer: @escaping Renderer,
            locale: Locale, colorScheme: ColorScheme
        ) {
            self.renderer = renderer
            let environmentChanged = self.locale != locale || self.colorScheme != colorScheme
            self.locale = locale
            self.colorScheme = colorScheme
            if content.map(\.id) == items.map(\.id) {
                for (old, new) in zip(content, items) where environmentChanged || old != new {
                    listView.update(new)
                }
            } else {
                listView.apply(items, animated: !content.isEmpty)
            }
            content = items
        }

        private func configure(_ row: TagFilterHostingRow, item: TagFilterListItem) {
            guard let renderer else { return }
            let root = renderer(item)
                .padding(.horizontal, Metrics.Space.s)
                .id(item.id)
                .environment(\.locale, locale)
                .environment(\.colorScheme, colorScheme)
            row.configure(rootView: AnyView(root))
        }
    }
}

@MainActor
private final class TagFilterHostingRow: ListRowView {
    private let hostingView = NSHostingView(rootView: AnyView(EmptyView()))
    override init(frame: CGRect) {
        super.init(frame: frame)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        hostingView.rootView = AnyView(EmptyView())
    }
    func configure(rootView: AnyView) { hostingView.rootView = rootView }
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
            tags: HostLibraryModel.demo().hostTags,
            selection: $selection,
            requestDelete: { _ in }
        )
    } actions: {
        Button("New Host") {}
    }
    .frame(width: 640)
}
