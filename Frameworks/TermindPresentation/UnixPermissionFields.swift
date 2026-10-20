// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain

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
                    toggle(row, bit: 1, label: String(localized: AppStrings.Common.execute), hideLabel: false)
                }
            }
        } else {
            Grid(horizontalSpacing: horizontalSpacing, verticalSpacing: verticalSpacing) {
                GridRow {
                    Color.clear.frame(width: 72, height: 1)
                    permissionHeader("Read")
                    permissionHeader("Write")
                    permissionHeader(AppStrings.Common.execute)
                }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(0..<3) { row in
                    GridRow {
                        Text(title(row)).frame(width: 72, alignment: .leading).foregroundStyle(.secondary)
                        permissionCell(row, bit: 4, label: String(localized: "Read"))
                        permissionCell(row, bit: 2, label: String(localized: "Write"))
                        permissionCell(row, bit: 1, label: String(localized: AppStrings.Common.execute))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func permissionHeader(_ title: LocalizedStringResource) -> some View {
        Text(title).frame(maxWidth: .infinity)
    }

    private func permissionCell(_ row: Int, bit: UInt32, label: String) -> some View {
        toggle(row, bit: bit, label: label, hideLabel: true)
            .frame(maxWidth: .infinity)
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
        case 1: String(localized: AppStrings.SFTP.permissionGroup)
        default: String(localized: "Others")
        }
    }
}
