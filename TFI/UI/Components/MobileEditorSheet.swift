// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain
import TermindPresentation

struct MobileEditorToolbarAction: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let systemImage: String
    var role: ButtonRole? = nil
    var startsGroup = false
    var isEnabled = true
    let perform: () -> Void
}

/// Presentation is mobile-owned; form content can also live in desktop work columns.
struct MobileEditorSheet<Content: View>: View {
    let title: String
    let isDirty: Bool
    var canSave = true
    var compact = false
    var actions: [MobileEditorToolbarAction] = []
    var onCancel: () -> Void = {}
    var topBar: AnyView? = nil
    var discardQuestion: LocalizedStringResource = AppStrings.Common.discardChangesQuestion
    let save: () async throws -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var showsDiscard = false
    @State private var error: String?
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let topBar {
                    topBar
                        .disabled(isSaving)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                    Divider()
                }
                Form {
                    content().disabled(isSaving)
                    if isSaving { ProgressView().frame(maxWidth: .infinity) }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.Common.cancel.swiftUIKey, systemImage: "xmark") {
                        if isDirty {
                            showsDiscard = true
                        } else {
                            cancel()
                        }
                    }
                    .labelStyle(.iconOnly).disabled(isSaving)
                    .confirmationDialog(Text(verbatim: ""), isPresented: $showsDiscard, titleVisibility: .hidden) {
                        Button(AppStrings.Common.discardChanges.swiftUIKey, role: .destructive, action: cancel)
                    } message: {
                        Text(discardQuestion)
                    }
                }
                if !actions.isEmpty {
                    MobileToolbarOverflow {
                        ForEach(actions) { action in
                            if action.startsGroup { Divider() }
                            Button(role: action.role, action: action.perform) {
                                Label(action.title, systemImage: action.systemImage)
                            }
                            .disabled(!action.isEnabled || isSaving)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: saveAndDismiss) {
                        Label(AppStrings.Common.save.swiftUIKey, systemImage: "checkmark")
                    }.labelStyle(.iconOnly).accessibilityLabel(Text(AppStrings.Common.save)).disabled(
                        !canSave || isSaving)
                }
                .mobileProminentAction()
            }
            .alert(
                AppStrings.Common.unableToSave,
                isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
            ) {
                Button(AppStrings.Common.ok.swiftUIKey, role: .cancel, action: { error = nil })
            } message: {
                Text(error ?? "")
            }
        }
        .mobileSheetPresentation(compact: compact)
        .interactiveDismissDisabled(isDirty || isSaving)
        .onChange(of: isDirty) { _, dirty in
            if !dirty { showsDiscard = false }
        }
        .onDisappear { saveTask?.cancel() }
    }

    private func saveAndDismiss() {
        guard canSave, !isSaving else { return }
        isSaving = true
        saveTask = Task {
            defer { isSaving = false }
            do {
                try await save()
                try Task.checkCancellation()
                dismiss()
            } catch is CancellationError {
            } catch { self.error = HostAccessError.presentationDescription(of: error) }
        }
    }

    private func cancel() {
        guard !isSaving else { return }
        onCancel()
        dismiss()
    }
}
