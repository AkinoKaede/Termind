// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain

public struct SecurityKeyEditorForm: View {
    @State private var model: SecurityKeyEditorModel
    @State private var task: Task<Void, Never>?
    private let close: () -> Void

    public init(
        existing: SSHKeyRef,
        exportReference: @escaping (SecurityKeyCredential) throws -> String,
        validate: @escaping (SecurityKeyCredential) throws -> Void,
        persist: @escaping (SSHKeyRef) throws -> Void,
        close: @escaping () -> Void
    ) {
        _model = State(
            initialValue: SecurityKeyEditorModel(
                existing: existing, exportReference: exportReference, validate: validate, persist: persist))
        self.close = close
    }

    public var body: some View {
        VStack(spacing: 0) {
            Form {
                SecurityKeyEditorSections(model: model, showsTitle: true)
            }
            .formStyle(.grouped)
            HStack {
                Button(AppStrings.Common.cancel.swiftUIKey) {
                    task?.cancel()
                    close()
                }
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button(AppStrings.Common.save.swiftUIKey) {
                    task = Task { if await model.save() { close() } }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)
            }.padding()
        }
        .task { model.load() }
        .onDisappear { task?.cancel() }
    }
}
