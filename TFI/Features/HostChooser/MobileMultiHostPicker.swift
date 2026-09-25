import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileMultiHostPicker: View {
    let title: LocalizedStringResource
    let actionTitle: LocalizedStringResource
    let emptyDescription: LocalizedStringResource
    let requiresSelection: Bool
    let save: ([Host.ID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var model: MobileMultiHostPickerModel

    init(
        library: HostLibraryModel, useCase: HostUseCase, selected: Set<Host.ID>,
        title: LocalizedStringResource, actionTitle: LocalizedStringResource,
        emptyDescription: LocalizedStringResource, requiresSelection: Bool,
        isEligible: @escaping (Host) -> Bool = { _ in true },
        save: @escaping ([Host.ID]) -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.emptyDescription = emptyDescription
        self.requiresSelection = requiresSelection
        self.save = save
        _model = State(
            initialValue: MobileMultiHostPickerModel(
                library: library, useCase: useCase, selected: selected, isEligible: isEligible))
    }

    var body: some View {
        NavigationStack {
            List {
                if model.isLibraryEmpty {
                    ContentUnavailableView(
                        AppStrings.Vault.noHosts.swiftUIKey, systemImage: "server.rack",
                        description: Text(emptyDescription)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if model.hosts.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        Button(
                            model.allResultsSelected ? AppStrings.Common.deselectAll : AppStrings.Common.selectAll,
                            action: model.toggleAllResults
                        )
                        .accessibilityIdentifier("host-picker.select-all")
                    }
                    Section {
                        ForEach(model.hosts) { host in
                            Button {
                                model.toggle(host.id)
                            } label: {
                                MobileHostPickerRow(host: host, loginAddress: model.loginAddress(for: host)) {
                                    if model.selected.contains(host.id) {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.tint)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("host-picker.host.\(host.id)")
                            .accessibilityAddTraits(model.selected.contains(host.id) ? [.isSelected] : [])
                        }
                    }
                }
            }
            .searchable(text: $model.query.singleLineText, prompt: AppStrings.Vault.searchHosts.swiftUIKey)
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.Common.cancel.swiftUIKey, systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, systemImage: "checkmark") {
                        save(model.orderedSelection)
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
                    .disabled(requiresSelection && model.orderedSelection.isEmpty)
                }
            }
            .onChange(of: model.availableHostIDs, initial: true) { model.reconcileSelection() }
        }
        .mobileSheetPresentation(compact: true)
    }
}
