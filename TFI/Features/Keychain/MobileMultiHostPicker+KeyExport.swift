import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

extension MobileMultiHostPicker where Header == MobileKeyExportHeader, RowDetail == MobileKeyExportHostDetail {
    init(
        library: HostLibraryModel, credentials: CredentialLibraryModel,
        exporting model: MobileKeyExportModel, close: @escaping () -> Void
    ) {
        self.init(
            library: library, useCase: .keyExport, selected: [],
            title: AppStrings.Keychain.exportToHosts,
            actionTitle: model.isFinished ? AppStrings.Common.done : AppStrings.Common.export,
            emptyDescription: AppStrings.Keychain.addAndConnectToAHostBeforeExportingAKeyToIt,
            requiresSelection: !model.isFinished,
            isSelectable: { credentials.keyExportUnavailableReason(for: $0) == nil },
            interaction: MobileMultiHostPickerInteraction(
                allowsSelection: !model.isExporting && !model.isFinished,
                allowsDismissal: !model.isExporting,
                allowsConfirmation: !model.isExporting,
                dismissesOnSave: false),
            displayedHosts: model.isExporting || model.isFinished ? model.targets : nil,
            selectionChanged: model.updateSelection,
            save: { hostIDs in
                if model.isFinished {
                    close()
                } else {
                    Task { await model.export(to: hostIDs) }
                }
            },
            header: { MobileKeyExportHeader(model: model) },
            rowDetail: { host in
                MobileKeyExportHostDetail(
                    state: model.states[host.id], unavailable: credentials.keyExportUnavailableReason(for: host))
            })
    }
}

struct MobileKeyExportHeader: View {
    let model: MobileKeyExportModel

    var body: some View {
        Section {
            Label(model.key.label, systemImage: "key")
            if model.isFinished {
                Text(model.summary).accessibilityIdentifier("key-export.summary")
            } else {
                Text(AppStrings.Common.selected(model.selected.count)).foregroundStyle(.secondary)
            }
        }
    }
}

struct MobileKeyExportHostDetail: View {
    let state: MobileKeyExportModel.ExportState?
    let unavailable: String?

    var body: some View {
        switch state {
        case .running:
            ProgressView()
        case .succeeded:
            Label(AppStrings.Keychain.exported.swiftUIKey, systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.red)
        case nil:
            if let unavailable {
                Text(unavailable).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
