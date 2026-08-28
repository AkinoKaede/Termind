import SwiftUI

/// One row in the left column: fixed glyph column, title, optional trailing
/// accessory, and the app's one selection highlight.
///
/// Shared so that every list in the sidebar lines up on the same rendered edge.
/// Batch Startup used to draw itself, which is why it sat 8pt to the left of the
/// destinations above it and never lit up under the pointer; the fix is not a
/// correction padding but using the same container.
struct SidebarNavigatorRow<Trailing: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    var isSelected = false
    var isEnabled = true
    /// What right-clicking the row offers. A destination's own creation verbs
    /// belong here as well as in the titlebar, so a host can be added without
    /// first going to the page that adds hosts.
    var menu: (() -> [NativeMenuEntry])?
    @ViewBuilder var trailing: Trailing
    let action: () -> Void

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.Space.s) {
                Image(systemName: symbol)
                    .foregroundStyle(SidebarSelectionStyle.foreground(
                        isSelected: isSelected,
                        controlActiveState: controlActiveState,
                        unselected: AnyShapeStyle(.secondary)
                    ))
                    .frame(width: Metrics.Sidebar.rowIcon)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(SidebarSelectionStyle.foreground(
                        isSelected: isSelected,
                        controlActiveState: controlActiveState,
                        unselected: AnyShapeStyle(.primary)
                    ))
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer(minLength: Metrics.Space.xs)
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.Sidebar.navigationRowHeight)
            .padding(.horizontal, Metrics.Sidebar.navigationRowInset)
            .contentShape(.rect)
            .modifier(SidebarRowChrome(isSelected: isSelected, menu: menu))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Picks the row treatment with or without a menu, so `SidebarNavigatorRow`
/// stays one type instead of branching its whole body.
private struct SidebarRowChrome: ViewModifier {
    let isSelected: Bool
    let menu: (() -> [NativeMenuEntry])?

    func body(content: Content) -> some View {
        if let menu {
            content.termindSidebarRow(isSelected: isSelected, menu: menu)
        } else {
            content.termindSidebarRowBackground(isSelected: isSelected)
        }
    }
}

extension SidebarNavigatorRow where Trailing == SidebarRowCount {
    /// The common form: a destination with how many things are behind it.
    init(
        title: LocalizedStringKey,
        symbol: String,
        count: Int,
        isSelected: Bool = false,
        menu: (() -> [NativeMenuEntry])? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title, symbol: symbol, isSelected: isSelected, menu: menu,
            trailing: { SidebarRowCount(count: count) }, action: action
        )
    }
}

extension SidebarNavigatorRow where Trailing == EmptyView {
    init(
        title: LocalizedStringKey,
        symbol: String,
        isSelected: Bool = false,
        menu: (() -> [NativeMenuEntry])? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title, symbol: symbol, isSelected: isSelected, menu: menu,
            trailing: { EmptyView() }, action: action
        )
    }
}

/// Nothing at all for zero, so a fresh install is not a column of noughts.
struct SidebarRowCount: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count, format: .number)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }
}

/// The collapsible heading above a group of sidebar rows.
struct SidebarSectionHeader: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: Metrics.Space.s) {
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: Metrics.Sidebar.rowIcon)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            .padding(
                .horizontal,
                Metrics.Sidebar.navigationRowInset + Metrics.Sidebar.rowHorizontalMargin
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .termindSidebarSectionLabel()
        .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))
        .accessibilityAction(named: Text(isExpanded ? "Collapse" : "Expand")) {
            isExpanded.toggle()
        }
    }
}

/// The local search at the foot of the Snippets and History modes.
///
/// It stays in the sidebar rather than moving to the titlebar because it narrows
/// the *sidebar's* list, which is a different question from the one the titlebar
/// field asks about the content in front. A native `NSSearchField` in a system
/// glass capsule, at one height for every mode.
struct SidebarSearchFooter: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        NativeSearchField(text: $text, placeholder: placeholder, controlSize: .large)
            .frame(height: Metrics.Sidebar.searchFieldHeight)
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.s)
    }
}
