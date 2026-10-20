// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication

/// Shared form behavior; the platform editor owns save, dismissal and cancellation.
public struct TailscaleGroupFields: View {
    @Bindable var editor: TailscaleGroupEditor
    let requireAccess: () -> Bool
    let copy: (String) -> Void

    public init(
        editor: TailscaleGroupEditor, requireAccess: @escaping () -> Bool, copy: @escaping (String) -> Void
    ) {
        self.editor = editor
        self.requireAccess = requireAccess
        self.copy = copy
    }

    public var body: some View {
        Group {
            Section {
                if editor.canChangeEnabled {
                    Toggle(
                        AppStrings.Common.enabled.swiftUIKey,
                        isOn: Binding(
                            get: { editor.enabled },
                            set: { value in if !value || requireAccess() { editor.setEnabled(value) } })
                    )
                } else {
                    TailscaleFormRow(label: AppStrings.Tailscale.status) {
                        Text(AppStrings.Connections.connected)
                    }
                }
            } header: {
                Text(AppStrings.Tailscale.title)
            } footer: {
                if editor.pending != nil {
                    Text(AppStrings.Tailscale.loginPendingSave)
                } else if editor.isLogoutPending {
                    Text(AppStrings.Tailscale.logoutPendingSave)
                }
            }
            if editor.enabled {
                if editor.isConnected {
                    Section {
                        if let network = editor.network {
                            TailscaleCopyField(
                                label: AppStrings.Tailscale.network, value: network.dnsSuffix, copy: copy)
                        }
                        TailscaleHostnameField(editor: editor)
                        TailscaleExitNodeField(editor: editor)
                        Button(role: .destructive) {
                            editor.logout()
                        } label: {
                            Label(
                                AppStrings.Tailscale.logout.swiftUIKey,
                                systemImage: "rectangle.portrait.and.arrow.right"
                            )
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    TailscaleDeviceFields(editor: editor, copy: copy)
                    if let error = editor.model.error {
                        Section { errorText(error) }
                    }
                } else {
                    Section {
                        TailscaleLoginFields(editor: editor, requireAccess: requireAccess)
                        if let error = editor.model.error { errorText(error) }
                    }
                }
            } else if let error = editor.model.error {
                Section { errorText(error) }
            }
        }
        .disabled(editor.isSaving)
        .onChange(of: editor.pending?.id) { _, _ in editor.receiveLogin() }
    }

    private func errorText(_ error: String) -> some View {
        Text(error).foregroundStyle(.red).font(.callout)
            .fixedSize(horizontal: false, vertical: true)
    }
}
