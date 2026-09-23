import AppKit
import SwiftUI
import TermindPresentation

/// The window-level presentation for Command-P.
///
/// The dimming layer owns dismissal while the glass surface intercepts clicks
/// inside its bounds. Keeping this out of `RootView` leaves the window shell in
/// charge of *when* the palette is visible and this view in charge of how it
/// behaves while it is visible.
struct QuickOpenOverlay: View {
    let dismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            TermindColor.shadow.opacity(colorScheme == .dark ? 0.14 : 0.07)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture(perform: close)

            QuickOpenView(dismiss: close)
                .shadow(
                    color: TermindColor.shadow.opacity(colorScheme == .dark ? 0.30 : 0.18),
                    radius: 32,
                    y: 14
                )
                .contentShape(.rect)
                .padding(Metrics.Space.xl)
        }
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AppStrings.Navigation.quickOpen))
    }

    private func close() {
        if reduceMotion {
            dismiss()
        } else {
            withAnimation(Motion.panel) { dismiss() }
        }
    }
}

struct QuickOpenView: View {
    let dismiss: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var selectedID: AppCommandDescriptor.ID?
    @FocusState private var searchFocused: Bool
    @Namespace private var glassNamespace

    private var results: QuickOpenResults {
        QuickOpenResults(
            commands: app.commands.commands(app: app, window: window),
            query: query
        )
    }

    var body: some View {
        glassIdentity(
            integratedContent
                .clipShape(.rect(cornerRadius: Metrics.QuickOpen.cornerRadius))
                .termindGlassSurface(
                    cornerRadius: Metrics.QuickOpen.cornerRadius,
                    isInteractive: true
                )
        )
        .frame(width: Metrics.QuickOpen.width, height: Metrics.QuickOpen.height)
        .onAppear {
            selectedID = results.commands.first?.id
        }
        .onChange(of: window.isQuickOpenPresented) {
            if !window.isQuickOpenPresented { searchFocused = false }
        }
        .onChange(of: query) {
            selectedID = results.commands.first?.id
        }
    }

    private var integratedContent: some View {
        VStack(spacing: 0) {
            searchHeader

            Divider()
                .opacity(0.48)
                .padding(.horizontal, Metrics.Space.xl)

            resultContent

            Divider()
                .opacity(0.36)
                .padding(.horizontal, Metrics.Space.xl)

            shortcutFooter
        }
    }

    @ViewBuilder
    private func glassIdentity<Content: View>(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffectID(QuickOpenGlassSurface.palette, in: glassNamespace)
                .glassEffectTransition(reduceMotion ? .identity : .materialize)
        } else {
            content
        }
    }

    private var searchHeader: some View {
        HStack(spacing: Metrics.Space.l) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                AppStrings.Navigation.searchPagesChatsWorkspacesHostsAndActions.swiftUIKey,
                text: $query.singleLineText,
                axis: .horizontal
            )
            .singleLinePaste()
            .lineLimit(1)
            .textFieldStyle(.plain)
            .font(.system(size: 17, weight: .medium))
            .focused($searchFocused)
            .background {
                QuickOpenFocusMount(isPresented: window.isQuickOpenPresented) {
                    guard window.isQuickOpenPresented else { return }
                    searchFocused = true
                }
            }
            .onSubmit(performSelection)
            .onKeyPress(.upArrow) { moveSelection(by: -1) }
            .onKeyPress(.downArrow) { moveSelection(by: 1) }
            .onExitCommand(perform: dismiss)
            .accessibilityLabel(Text(AppStrings.Navigation.searchQuickOpen))

            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(Text(AppStrings.Common.clearSearch))
                .accessibilityLabel(Text(AppStrings.Common.clearSearch))
            }

            QuickOpenKeycap(keys: "esc")
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Metrics.Space.xl)
        .frame(height: Metrics.QuickOpen.searchHeight)
    }

    @ViewBuilder
    private var resultContent: some View {
        if results.commands.isEmpty {
            VStack(spacing: Metrics.Space.m) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(AppStrings.Common.noResults)
                    .font(.headline)
                Text(AppStrings.Common.noResultsMatch(query))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(listItems) { item in
                            Group {
                                switch item {
                                case .section(let section):
                                    quickOpenSection(section)
                                case .command(let command, let isSelected):
                                    quickOpenCommand(command, isSelected: isSelected)
                                }
                            }
                            .frame(height: item.height)
                            .id(item.id)
                        }
                    }
                    .padding(.vertical, Metrics.Space.xs)
                }
                .onAppear { scrollSelectionIntoView(using: proxy) }
                .onChange(of: selectedID) { _, _ in scrollSelectionIntoView(using: proxy) }
            }
        }
    }

    private var listItems: [QuickOpenListItem] {
        results.listItems(selectedID: selectedID)
    }

    private func scrollSelectionIntoView(using proxy: ScrollViewProxy) {
        guard let selectedID else { return }
        proxy.scrollTo(QuickOpenListItem.ID.command(selectedID))
    }

    private func quickOpenSection(_ section: AppCommandSection) -> some View {
        Text(section.title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, Metrics.Space.xl + Metrics.Space.xs)
            .padding(.bottom, Metrics.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func quickOpenCommand(
        _ command: AppCommandDescriptor,
        isSelected: Bool
    ) -> some View {
        Button {
            perform(command)
        } label: {
            HStack(spacing: Metrics.Space.l) {
                Image(systemName: command.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
                    )
                    .frame(width: Metrics.QuickOpen.iconSize, height: Metrics.QuickOpen.iconSize)
                    .background(
                        isSelected
                            ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                            : AnyShapeStyle(Color.primary.opacity(0.055)),
                        in: .rect(cornerRadius: Metrics.Radius.medium)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Metrics.Space.xxs) {
                    Text(command.title)
                        .font(.callout.weight(isSelected ? .medium : .regular))
                        .lineLimit(1)
                    if let subtitle = command.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                Highlight.fill(isSelected: isSelected),
                in: .rect(cornerRadius: Metrics.QuickOpen.selectionCornerRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.QuickOpen.selectionCornerRadius)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.24) : .clear,
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .contentShape(.rect(cornerRadius: Metrics.QuickOpen.selectionCornerRadius))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Metrics.Space.s)
        .onHover { hovering in
            if hovering { selectedID = command.id }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(commandAccessibilityLabel(command))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(reduceMotion ? nil : Motion.workspaceSwitch, value: isSelected)
    }

    private var shortcutFooter: some View {
        HStack(spacing: Metrics.Space.xl) {
            QuickOpenShortcutHint(keys: "↑↓", label: String(localized: AppStrings.Navigation.navigate))
            QuickOpenShortcutHint(keys: "↩", label: String(localized: AppStrings.Common.open))
            QuickOpenShortcutHint(keys: "esc", label: String(localized: AppStrings.Common.close))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.Space.xl)
        .frame(height: Metrics.QuickOpen.footerHeight)
        .accessibilityHidden(true)
    }

    private func commandAccessibilityLabel(_ command: AppCommandDescriptor) -> Text {
        if let subtitle = command.subtitle {
            Text("\(command.title), \(subtitle)")
        } else {
            Text(command.title)
        }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        guard let next = results.selection(movingFrom: selectedID, by: offset) else {
            return .ignored
        }
        selectedID = next
        return .handled
    }

    private func performSelection() {
        let command =
            selectedID.flatMap { id in results.commands.first { $0.id == id } }
            ?? results.commands.first
        if let command { perform(command) }
    }

    private func perform(_ command: AppCommandDescriptor) {
        app.commands.perform(command.target, app: app, window: window)
        dismiss()
    }
}

private nonisolated enum QuickOpenGlassSurface: Hashable, Sendable {
    case palette
}

/// SwiftUI can run `onAppear` before the search field joins its window. Request
/// focus after AppKit mounts it, and retire that request even during a closing transition.
private struct QuickOpenFocusMount: NSViewRepresentable {
    let isPresented: Bool
    let focus: () -> Void

    func makeNSView(context: Context) -> MountView {
        let view = MountView()
        view.focus = focus
        view.isPresented = isPresented
        return view
    }

    func updateNSView(_ view: MountView, context: Context) {
        view.focus = focus
        view.isPresented = isPresented
    }

    static func dismantleNSView(_ view: MountView, coordinator: ()) {
        view.isPresented = false
        view.focus = nil
    }

    final class MountView: NSView {
        var focus: (() -> Void)?
        var isPresented = false {
            didSet {
                if isPresented != oldValue { scheduleFocus() }
            }
        }
        private var generation: UInt64 = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleFocus()
        }

        private func scheduleFocus() {
            generation &+= 1
            guard isPresented else { return }
            let request = generation
            DispatchQueue.main.async { [weak self] in
                self?.deliverFocus(request: request, remainingAttempts: 20)
            }
        }

        private func deliverFocus(request: UInt64, remainingAttempts: Int) {
            guard isPresented, generation == request, let window, self.window === window else {
                return
            }
            guard window.isKeyWindow else {
                guard remainingAttempts > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.deliverFocus(
                        request: request,
                        remainingAttempts: remainingAttempts - 1
                    )
                }
                return
            }
            focus?()
        }
    }
}

private struct QuickOpenShortcutHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            QuickOpenKeycap(keys: keys)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct QuickOpenKeycap: View {
    let keys: String

    var body: some View {
        Text(verbatim: keys)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.Space.s)
            .frame(minWidth: 22, minHeight: 18)
            .background(
                Color.primary.opacity(0.055),
                in: .rect(cornerRadius: Metrics.Radius.small)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.Radius.small)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            }
    }
}

nonisolated struct QuickOpenResults: Equatable, Sendable {
    let commands: [AppCommandDescriptor]

    init(commands: [AppCommandDescriptor], query: String) {
        let matches = commands.filter { $0.matches(query) }
        self.commands = AppCommandSection.allCases.flatMap { section in
            matches.filter { $0.section == section }
        }
    }

    var sections: [AppCommandSection] {
        AppCommandSection.allCases.filter { section in
            commands.contains { $0.section == section }
        }
    }

    func listItems(selectedID: AppCommandDescriptor.ID?) -> [QuickOpenListItem] {
        sections.flatMap { section in
            [.section(section)]
                + commands.compactMap { command in
                    guard command.section == section else { return nil }
                    return .command(command, isSelected: command.id == selectedID)
                }
        }
    }

    func selection(
        movingFrom selectedID: AppCommandDescriptor.ID?,
        by offset: Int
    ) -> AppCommandDescriptor.ID? {
        guard !commands.isEmpty else { return nil }
        let current =
            selectedID.flatMap { id in commands.firstIndex { $0.id == id } }
            ?? (offset > 0 ? -1 : commands.count)
        let next = min(max(current + offset, 0), commands.count - 1)
        return commands[next].id
    }
}

nonisolated enum QuickOpenListItem: Identifiable, Hashable, Sendable {
    nonisolated enum ID: Hashable, Sendable {
        case section(AppCommandSection)
        case command(AppCommandDescriptor.ID)
    }

    case section(AppCommandSection)
    case command(AppCommandDescriptor, isSelected: Bool)

    var id: ID {
        switch self {
        case .section(let section): .section(section)
        case .command(let command, _): .command(command.id)
        }
    }

    var height: CGFloat {
        switch self {
        case .section: Metrics.QuickOpen.sectionHeight
        case .command: Metrics.QuickOpen.rowHeight
        }
    }

    var isSelected: Bool {
        guard case .command(_, let isSelected) = self else { return false }
        return isSelected
    }
}
