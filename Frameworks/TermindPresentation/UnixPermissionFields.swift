import SwiftUI
import TermindDomain

public struct UnixPermissionFields: View {
    @Binding private var draft: SFTPPermissionDraft
    public init(draft: Binding<SFTPPermissionDraft>) { _draft = draft }

    public var body: some View {
        Section("Permissions") {
            TextField("Octal permissions", text: Binding(get: { draft.text }, set: { _ = draft.accept($0) }))
                .font(.body.monospaced())
                #if os(iOS)
                    .multilineTextAlignment(.leading)
                    .keyboardType(.numberPad)
                #endif
        }
        Section("File Access") { UnixPermissionGrid(draft: $draft) }
        Section("Special Permissions") {
            Toggle("Set UID", isOn: permission(0o4000))
            Toggle("Set GID", isOn: permission(0o2000))
            Toggle("Sticky Bit", isOn: permission(0o1000))
        }
    }

    private func permission(_ mask: UInt32) -> Binding<Bool> {
        Binding(get: { draft.contains(mask) }, set: { draft.set(mask, enabled: $0) })
    }
}

public struct UnixPermissionGrid: View {
    @Binding private var draft: SFTPPermissionDraft
    private let horizontalSpacing: CGFloat
    private let verticalSpacing: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(draft: Binding<SFTPPermissionDraft>, horizontalSpacing: CGFloat = 16, verticalSpacing: CGFloat = 12) {
        _draft = draft
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: verticalSpacing) {
                ForEach(0..<3) { row in
                    Text(title(row)).font(.headline)
                    toggle(row, bit: 4, label: String(localized: "Read"), hideLabel: false)
                    toggle(row, bit: 2, label: String(localized: "Write"), hideLabel: false)
                    toggle(row, bit: 1, label: String(localized: "Execute"), hideLabel: false)
                }
            }
        } else {
            Grid(horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing) {
                GridRow {
                    Color.clear.frame(width: 72, height: 1)
                    Text("Read")
                    Text("Write")
                    Text("Execute")
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(0..<3) { row in
                    GridRow {
                        Text(title(row)).frame(width: 72, alignment: .leading).foregroundStyle(.secondary)
                        toggle(row, bit: 4, label: String(localized: "Read"), hideLabel: true)
                        toggle(row, bit: 2, label: String(localized: "Write"), hideLabel: true)
                        toggle(row, bit: 1, label: String(localized: "Execute"), hideLabel: true)
                    }
                }
            }
        }
    }

    @ViewBuilder private func toggle(_ row: Int, bit: UInt32, label: String, hideLabel: Bool) -> some View {
        let mask = bit << ((2 - row) * 3)
        let control = Toggle(label, isOn: Binding(get: { draft.contains(mask) }, set: { draft.set(mask, enabled: $0) }))
            .accessibilityLabel("\(title(row)), \(label)")
            .toggleStyle(.switch).controlSize(.small)
        if hideLabel { control.labelsHidden() } else { control }
    }

    private func title(_ index: Int) -> String {
        switch index {
        case 0: String(localized: "Owner")
        case 1: String(localized: "Group")
        default: String(localized: "Others")
        }
    }
}
