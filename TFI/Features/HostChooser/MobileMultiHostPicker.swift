// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileMultiHostPicker<Header: View, RowDetail: View>: View {
    let title: LocalizedStringResource
    let actionTitle: LocalizedStringResource
    let emptyDescription: LocalizedStringResource
    let requiresSelection: Bool
    let save: ([Host.ID]) -> Void
    let useCase: HostUseCase
    let header: Header
    let interaction: MobileMultiHostPickerInteraction
    let displayedHosts: [Host]?
    let rowDetail: (Host) -> RowDetail
    let selectionChanged: (Set<Host.ID>) -> Void

    private var hosts: [Host] { displayedHosts ?? model.hosts }
    @Environment(\.dismiss) private var dismiss
    @State private var model: MobileMultiHostPickerModel

    init(
        library: HostLibraryModel, useCase: HostUseCase, selected: Set<Host.ID>,
        title: LocalizedStringResource, actionTitle: LocalizedStringResource,
        emptyDescription: LocalizedStringResource, requiresSelection: Bool,
        isEligible: @escaping (Host) -> Bool = { _ in true },
        isSelectable: @escaping (Host) -> Bool = { _ in true },
        interaction: MobileMultiHostPickerInteraction = .standard,
        displayedHosts: [Host]? = nil,
        selectionChanged: @escaping (Set<Host.ID>) -> Void = { _ in },
        save: @escaping ([Host.ID]) -> Void,
        @ViewBuilder header: () -> Header,
        @ViewBuilder rowDetail: @escaping (Host) -> RowDetail
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.emptyDescription = emptyDescription
        self.requiresSelection = requiresSelection
        self.save = save
        self.useCase = useCase
        self.header = header()
        self.interaction = interaction
        self.displayedHosts = displayedHosts
        self.rowDetail = rowDetail
        self.selectionChanged = selectionChanged
        _model = State(
            initialValue: MobileMultiHostPickerModel(
                library: library, useCase: useCase, selected: selected, isEligible: isEligible,
                isSelectable: isSelectable))
    }

    var body: some View {
        NavigationStack {
            List {
                header

                if model.isLibraryEmpty, displayedHosts == nil {
                    ContentUnavailableView(
                        AppStrings.Vault.noHosts.swiftUIKey, systemImage: "server.rack",
                        description: Text(emptyDescription)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if hosts.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    if interaction.allowsSelection {
                        Section {
                            Button(
                                model.allResultsSelected ? AppStrings.Common.deselectAll : AppStrings.Common.selectAll,
                                action: model.toggleAllResults
                            )
                            .disabled(model.selectableHosts.isEmpty)
                            .accessibilityIdentifier("host-picker.select-all")
                        }
                    }
                    Section {
                        ForEach(hosts) { host in
                            Button {
                                model.toggle(host.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    MobileHostPickerRow(host: host, loginAddress: model.loginAddress(for: host)) {
                                        if model.selected.contains(host.id) {
                                            Image(systemName: "checkmark")
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(.tint)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    rowDetail(host)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!interaction.allowsSelection || !model.isSelectable(host))
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
                        .disabled(!interaction.allowsDismissal)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionTitle, systemImage: "checkmark") {
                        model.updateUseCase(useCase)
                        save(model.orderedSelection)
                        if interaction.dismissesOnSave { dismiss() }
                    }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.tint)
                    .disabled(!interaction.allowsConfirmation || (requiresSelection && model.orderedSelection.isEmpty))
                    .accessibilityIdentifier("host-picker.confirm")
                }
            }
            .onChange(of: model.availableHostIDs, initial: true) { model.reconcileSelection() }
            .onChange(of: useCase) { model.updateUseCase(useCase) }
            .onChange(of: model.selected, initial: true) { selectionChanged(model.selected) }
        }
        .interactiveDismissDisabled(!interaction.allowsDismissal)
        .mobileSheetPresentation(compact: true)
    }
}

extension MobileMultiHostPicker where Header == EmptyView, RowDetail == EmptyView {
    init(
        library: HostLibraryModel, useCase: HostUseCase, selected: Set<Host.ID>,
        title: LocalizedStringResource, actionTitle: LocalizedStringResource,
        emptyDescription: LocalizedStringResource, requiresSelection: Bool,
        isEligible: @escaping (Host) -> Bool = { _ in true },
        save: @escaping ([Host.ID]) -> Void
    ) {
        self.init(
            library: library, useCase: useCase, selected: selected, title: title, actionTitle: actionTitle,
            emptyDescription: emptyDescription, requiresSelection: requiresSelection,
            isEligible: isEligible, save: save, header: { EmptyView() }, rowDetail: { _ in EmptyView() })
    }
}

extension MobileMultiHostPicker where RowDetail == EmptyView {
    init(
        library: HostLibraryModel, useCase: HostUseCase, selected: Set<Host.ID>,
        title: LocalizedStringResource, actionTitle: LocalizedStringResource,
        emptyDescription: LocalizedStringResource, requiresSelection: Bool,
        isEligible: @escaping (Host) -> Bool = { _ in true },
        save: @escaping ([Host.ID]) -> Void,
        @ViewBuilder header: () -> Header
    ) {
        self.init(
            library: library, useCase: useCase, selected: selected, title: title, actionTitle: actionTitle,
            emptyDescription: emptyDescription, requiresSelection: requiresSelection,
            isEligible: isEligible, save: save, header: header, rowDetail: { _ in EmptyView() })
    }
}
