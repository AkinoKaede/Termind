import SwiftUI

/// The strip at the top of a manager page: a filter field on the left, the
/// page's own actions on the right.
///
/// A `safeAreaInset` rather than window-toolbar items, because these controls
/// belong to the *page*. Pages are ordinary tabs here, so anything put in the
/// window toolbar would still be sitting there when the front tab is a terminal.
struct PageToolbar<Accessory: View, Actions: View>: View {
    @Binding var query: String
    var prompt: LocalizedStringKey
    /// Sits immediately right of the filter field, for a page that narrows its
    /// list by something the field cannot express — the Hosts page's tag
    /// filter. Next to the field rather than over with the actions on purpose:
    /// it is part of the same question, not another verb.
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            filterField
            accessory
            Spacer(minLength: Metrics.Space.m)
            actions
        }
        .controlSize(.small)
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.m)
        .background(.bar)
    }

    private var filterField: some View {
        TermindSearchField(text: $query, prompt: prompt, density: .compact)
            .frame(maxWidth: 240)
    }
}

extension PageToolbar where Accessory == EmptyView {
    /// The plain form, for the four pages that have nothing to put beside the
    /// filter field.
    init(
        query: Binding<String>,
        prompt: LocalizedStringKey,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(query: query, prompt: prompt, accessory: { EmptyView() }, actions: actions)
    }
}

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
        .background(.bar)
    }
}
