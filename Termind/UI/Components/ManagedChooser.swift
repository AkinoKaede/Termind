import SwiftUI

enum ManagedChooserMode: Sendable {
    case single
    case multiple
}

@Observable
final class ManagedChooserState<ID: Hashable> {
    let mode: ManagedChooserMode
    var query = ""
    var cursor: ID?
    var selected: Set<ID>

    init(mode: ManagedChooserMode, selected: Set<ID> = []) {
        self.mode = mode
        self.selected = selected
    }

    // Swift 6.3.3's EarlyPerfInliner crashes while synthesizing this generic
    // class's optimized destructor. Keeping just the destructor unoptimized
    // preserves normal release optimization for the chooser and the app.
    @_optimize(none) deinit {}

    func activate(_ id: ID) {
        cursor = id
        switch mode {
        case .single:
            selected = [id]
        case .multiple:
            toggle(id)
        }
    }

    func toggle(_ id: ID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func moveCursor(by delta: Int, through ids: [ID]) {
        guard !ids.isEmpty else {
            cursor = nil
            return
        }
        guard let cursor, let index = ids.firstIndex(of: cursor) else {
            self.cursor = delta > 0 ? ids.first : ids.last
            return
        }
        self.cursor = ids[min(max(index + delta, 0), ids.count - 1)]
    }

    func queryDidChange(visible ids: [ID], enabled: Set<ID>) {
        let eligible = ids.filter(enabled.contains)
        cursor = query.isEmpty ? nil : eligible.first
        if mode == .single { selected = cursor.map { [$0] } ?? [] }
    }

    func toggleAll(visible ids: [ID], enabled: Set<ID>) {
        let eligible = ids.filter(enabled.contains)
        if !eligible.isEmpty, eligible.allSatisfy(selected.contains) {
            selected.subtract(eligible)
        } else {
            selected.formUnion(eligible)
        }
    }

}

struct SelectionMark: View {
    let mode: ManagedChooserMode
    let isSelected: Bool

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            .imageScale(.large)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch (mode, isSelected) {
        case (.single, true): "circle.inset.filled"
        case (.single, false): "circle"
        case (.multiple, true): "checkmark.square.fill"
        case (.multiple, false): "square"
        }
    }
}
