import AppKit
import SwiftUI
import TermindPresentation

/// A transparent native field for inline renaming inside emphasized sidebar
/// rows. Return commits, Escape cancels, and a pointer exit commits only after
/// the original click reaches its destination.
struct SidebarInlineRenameField: NSViewRepresentable {
    @Binding var text: String
    let prompt: String
    let isSelected: Bool
    let controlActiveState: ControlActiveState
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        field.stringValue = text
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(field)
        context.coordinator.requestFocus(for: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context _: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        configure(field)
    }

    static func dismantleNSView(_: NSTextField, coordinator: Coordinator) {
        coordinator.stopObservingPointerExit()
    }

    private func configure(_ field: NSTextField) {
        let font = NSFont.systemFont(
            ofSize: NSFont.systemFontSize,
            weight: isSelected ? .semibold : .regular
        )
        field.font = font
        field.textColor = textColor
        field.placeholderAttributedString = NSAttributedString(
            string: prompt,
            attributes: [.font: font, .foregroundColor: placeholderColor]
        )
        field.currentEditor()?.textColor = textColor
        field.currentEditor()?.drawsBackground = false
    }

    private var textColor: NSColor {
        controlActiveState == .key ? .labelColor : .secondaryLabelColor
    }

    private var placeholderColor: NSColor {
        guard isSelected else { return .secondaryLabelColor }
        return textColor.withAlphaComponent(0.72)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        private var text: Binding<String>
        private let onSubmit: () -> Void
        private let onCancel: () -> Void
        private var didFinish = false
        private var pointerMonitor: Any?
        private var windowResignObserver: (any NSObjectProtocol)?
        private var commitsAfterMouseUp = false

        init(
            text: Binding<String>,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func requestFocus(for field: NSTextField) {
            DispatchQueue.main.async {
                guard !self.didFinish, let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.drawsBackground = false
                field.currentEditor()?.selectAll(nil)
                self.observePointerExit(from: field)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField,
                let value = SingleLineFieldEditing.normalizedValue(in: field)
            else { return }
            text.wrappedValue = value
        }

        func controlTextDidEndEditing(_: Notification) {
            guard !didFinish, !commitsAfterMouseUp else { return }
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseUp,
                .rightMouseDown, .rightMouseUp,
                .otherMouseDown, .otherMouseUp:
                break
            default:
                finish(with: onSubmit)
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                finish(with: onSubmit)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                finish(with: onCancel)
                return true
            default:
                return false
            }
        }

        @objc func submit() {
            finish(with: onSubmit)
        }

        private func finish(with action: () -> Void) {
            guard !didFinish else { return }
            didFinish = true
            stopObservingPointerExit()
            action()
        }

        private func observePointerExit(from field: NSTextField) {
            guard pointerMonitor == nil else { return }
            pointerMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .leftMouseDown, .leftMouseUp,
                    .rightMouseDown, .rightMouseUp,
                    .otherMouseDown, .otherMouseUp,
                ]
            ) { [weak self, weak field] event in
                guard let self, let field else { return event }
                switch event.type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    guard event.window === field.window else {
                        self.commitsAfterMouseUp = true
                        return event
                    }
                    let point = field.convert(event.locationInWindow, from: nil)
                    self.commitsAfterMouseUp = !field.bounds.contains(point)
                case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                    guard self.commitsAfterMouseUp else { return event }
                    self.commitsAfterMouseUp = false
                    self.finishAfterCurrentEvent(with: self.onSubmit)
                default:
                    break
                }
                return event
            }
            guard let window = field.window else { return }
            windowResignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.finish(with: self.onSubmit)
                }
            }
        }

        func stopObservingPointerExit() {
            if let pointerMonitor {
                NSEvent.removeMonitor(pointerMonitor)
                self.pointerMonitor = nil
            }
            if let windowResignObserver {
                NotificationCenter.default.removeObserver(windowResignObserver)
                self.windowResignObserver = nil
            }
            commitsAfterMouseUp = false
        }

        private func finishAfterCurrentEvent(with action: @escaping () -> Void) {
            guard !didFinish else { return }
            didFinish = true
            stopObservingPointerExit()
            DispatchQueue.main.async { action() }
        }
    }
}

/// One row in the left column: fixed glyph column, title, optional trailing
/// accessory, and the app's one selection highlight.
///
/// Shared so that every list in the sidebar lines up on the same rendered edge.
/// Batch Startup used to draw itself, which is why it sat 8pt to the left of the
/// destinations above it and never lit up under the pointer; the fix is not a
/// correction padding but using the same container.
struct SidebarNavigatorRow<Trailing: View>: View {
    let title: LocalizedStringResource
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
                    .foregroundStyle(
                        SidebarSelectionStyle.iconForeground(
                            isSelected: isSelected,
                            controlActiveState: controlActiveState
                        )
                    )
                    .frame(width: Metrics.Sidebar.rowIcon)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(
                        SidebarSelectionStyle.foreground(
                            isSelected: isSelected,
                            controlActiveState: controlActiveState,
                            unselected: AnyShapeStyle(.primary)
                        )
                    )
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
        .termindInputAwareFocusEffect()
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
        title: LocalizedStringResource,
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
        title: LocalizedStringResource,
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
    let title: Text
    var count: Int?
    var height: CGFloat
    @Binding var isExpanded: Bool

    init(
        title: LocalizedStringResource, count: Int? = nil, height: CGFloat = 32,
        isExpanded: Binding<Bool>
    ) {
        self.title = Text(title)
        self.count = count
        self.height = height
        _isExpanded = isExpanded
    }

    init(
        title: String, count: Int? = nil, height: CGFloat = 32,
        isExpanded: Binding<Bool>
    ) {
        self.title = Text(title)
        self.count = count
        self.height = height
        _isExpanded = isExpanded
    }

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: Metrics.Space.s) {
                title
                Spacer(minLength: 0)
                if let count {
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: Metrics.Sidebar.rowIcon)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .padding(
                .horizontal,
                Metrics.Sidebar.navigationRowInset + Metrics.Sidebar.rowHorizontalMargin
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .termindSidebarSectionLabel()
        .accessibilityValue(Text(isExpanded ? AppStrings.Assistant.expanded : AppStrings.Assistant.collapsed))
        .accessibilityAction(named: Text(isExpanded ? AppStrings.Common.collapse : AppStrings.Common.expand)) {
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
        NativeSearchField(text: $text, placeholder: placeholder, controlSize: .large).singleLinePaste()
            .frame(height: Metrics.Sidebar.searchFieldHeight)
            .padding(.horizontal, Metrics.Space.m)
            .padding(.vertical, Metrics.Space.s)
    }
}
