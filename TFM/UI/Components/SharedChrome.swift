import SwiftUI

extension View {
    func termindTransientOverlaySurface() -> some View {
        termindGlassSurface(cornerRadius: Metrics.Radius.large)
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.Radius.large)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
            }
            .shadow(color: TermindColor.shadow.opacity(0.16), radius: 12, y: 5)
            .allowsHitTesting(false)
    }
}

/// A form row that opens a creation or configuration flow.
///
/// The full row is the hit target; the chevron communicates that the action
/// continues elsewhere rather than taking effect immediately.
struct FormNavigationAction: View {
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Metrics.Space.m) {
                Text(title)
                Spacer(minLength: Metrics.Space.m)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

enum TermindSearchFieldDensity {
    case compact, regular, prominent
}

struct TermindSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    var density: TermindSearchFieldDensity = .regular
    var externalFocus: FocusState<Bool>.Binding?

    @FocusState private var localFocus: Bool

    var body: some View {
        fieldContent
            .termindGlassSurface(
                cornerRadius: density == .prominent
                    ? Metrics.Radius.large : Metrics.Radius.medium,
                isInteractive: true
            )
    }

    private var fieldContent: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(density == .prominent ? .title3 : .body)
                .focused(externalFocus ?? $localFocus)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }

    private var horizontalPadding: CGFloat {
        density == .prominent ? Metrics.Space.l : Metrics.Space.s
    }

    private var verticalPadding: CGFloat {
        switch density {
        case .compact: Metrics.Space.xs
        case .regular: Metrics.Space.s
        case .prominent: Metrics.Space.m
        }
    }
}

struct SheetScaffold<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: .infinity)
                .termindGlassBar()
            Divider().opacity(0.7)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TermindColor.windowSurface)
            Divider().opacity(0.7)
            footer
                .termindGlassBar()
        }
    }
}

/// The stable chrome for work performed in Vault's third column. It deliberately
/// resembles the manager toolbars rather than a floating sheet: a clear close
/// affordance, a quiet title, scrollable work, and actions anchored at the foot.
struct VaultDetailScaffold<Content: View, Footer: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    let close: () -> Void
    var closeLabel: LocalizedStringKey = "Close"
    var closeSymbol = "xmark"
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.Space.m) {
                Button(action: close) {
                    Label(closeLabel, systemImage: closeSymbol)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help(closeLabel)

                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.m)
            .termindGlassBar()

            Divider().opacity(0.25)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TermindColor.windowSurface)
            Divider().opacity(0.25)
            footer
                .termindGlassBar()
        }
    }
}

struct ManagedChooserHeader: View {
    let title: LocalizedStringKey
    let symbol: String
    let prompt: LocalizedStringKey
    @Binding var query: String
    var aboveSearch: AnyView? = nil
    var showsSearch = true
    var onSubmit: () -> Void = {}
    var moveCursor: (Int) -> KeyPress.Result = { _ in .ignored }
    var toggleCursor: () -> KeyPress.Result = { .ignored }

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .labelStyle(.titleOnly)

            if let aboveSearch {
                aboveSearch
            }

            if showsSearch {
                searchRow
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
            }
        }
        .padding(Metrics.Space.xl)
        .animation(Motion.panel, value: showsSearch)
        .onAppear {
            if showsSearch { searchFocused = true }
        }
        .onChange(of: showsSearch) { _, visible in
            if visible {
                Task { @MainActor in searchFocused = true }
            } else {
                searchFocused = false
            }
        }
    }

    private var searchRow: some View {
        HStack(spacing: Metrics.Space.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.upArrow) { moveCursor(-1) }
                .onKeyPress(.downArrow) { moveCursor(1) }
                .onKeyPress(.space, action: toggleCursor)

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(Metrics.Space.s)
        .background(
            .quaternary.opacity(0.5),
            in: .rect(cornerRadius: Metrics.Radius.medium)
        )
    }
}

struct SelectableRow<Content: View, Trailing: View>: View {
    let isCursor: Bool
    let isSelected: Bool
    var isEnabled = true
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            content
            Spacer(minLength: Metrics.Space.s)
            trailing
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.Space.m)
        .padding(.vertical, Metrics.Space.s)
        .background(fill, in: .rect(cornerRadius: Metrics.Radius.medium))
        .overlay(alignment: .leading) {
            if isCursor {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2.5)
                    .padding(.vertical, Metrics.Space.xs)
            }
        }
        .contentShape(.rect(cornerRadius: Metrics.Radius.medium))
        .onHover { isHovering = $0 && isEnabled }
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var fill: Color {
        if isCursor { return Color.accentColor.opacity(0.11) }
        if isSelected { return Color.primary.opacity(0.075) }
        if isHovering { return Color.primary.opacity(0.045) }
        return .clear
    }
}
