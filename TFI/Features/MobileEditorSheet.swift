import SwiftUI

/// Presentation is mobile-owned; form content can also live in desktop work columns.
struct MobileEditorSheet<Content: View>: View {
    let title: String
    let isDirty: Bool
    var canSave = true
    var compact = false
    let save: () async throws -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
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
                        Button("Cancel") { if isDirty { discard = true } else { dismiss() } }.disabled(isSaving)
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
                            if isSaving { ProgressView() } else { Text("Save") }
                        }.disabled(!canSave || isSaving)
                    }
                }
                .confirmationDialog("Discard Changes?", isPresented: $discard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { dismiss() }
                }
                .alert("Unable to Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) { error = nil }
                } message: {
                    Text(error ?? "")
                }
        }
        .presentationDetents(compact && !typeSize.isAccessibilitySize ? [.medium, .large] : [.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isDirty || isSaving)
        .onDisappear { saveTask?.cancel() }
    }
}
