import SwiftUI

struct MobileEditorToolbarAction: Identifiable {
    let id: String
    let title: LocalizedStringKey
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
    let save: () async throws -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @State private var discard = false
    @State private var error: String?
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form { content().disabled(isSaving) }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") {
                            if isDirty {
                                discard = true
                            } else {
                                cancel()
                            }
                        }
                        .labelStyle(.iconOnly).disabled(isSaving)
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !actions.isEmpty {
                            Menu {
                                ForEach(actions) { action in
                                    if action.startsGroup { Divider() }
                                    Button(role: action.role, action: action.perform) {
                                        Label(action.title, systemImage: action.systemImage)
                                    }
                                    .disabled(!action.isEnabled || isSaving)
                                }
                            } label: {
                                MobileOverflowMenuLabel("More")
                            }
                            .disabled(isSaving)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            guard !isSaving else { return }
                            isSaving = true
                            saveTask = Task {
                                defer { isSaving = false }
                                do {
                                    try await save()
                                    try Task.checkCancellation()
                                    dismiss()
                                } catch is CancellationError {
                                } catch { self.error = error.localizedDescription }
                            }
                        } label: {
                            if isSaving { ProgressView() } else { Label("Save", systemImage: "checkmark") }
                        }.labelStyle(.iconOnly).accessibilityLabel(Text("Save")).disabled(!canSave || isSaving)
                    }
                }
                .confirmationDialog("Discard Changes?", isPresented: $discard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive, action: cancel)
                }
                .alert("Unable to Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) { error = nil }
                } message: {
                    Text(error ?? "")
                }
        }
        .mobileSheetPresentation(compact: compact)
        .interactiveDismissDisabled(isDirty || isSaving)
        .onDisappear { saveTask?.cancel() }
    }

    private func cancel() {
        onCancel()
        dismiss()
    }
}
