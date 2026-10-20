// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindDomain

public struct KeyExportForm: View {
    @Bindable private var model: KeyExportModel
    @State private var advanced = false

    public init(model: KeyExportModel) { self.model = model }

    public var body: some View {
        Form {
            if let key = model.key {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(key.label).font(.headline)
                            Text(
                                key.algorithm == .unknown
                                    ? AppStrings.Keychain.unknownKeyType
                                    : AppStrings.Keychain.keyType(key.algorithm.displayName)
                            ).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if model.phase == .succeeded {
                Section {
                    Label(AppStrings.KeyExport.completed.swiftUIKey, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else if case .attachmentFailed(let message) = model.phase {
                Section {
                    Label(AppStrings.KeyExport.attachmentFailed.swiftUIKey, systemImage: "exclamationmark.triangle")
                    Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button(AppStrings.KeyExport.retryAttachment.swiftUIKey) { model.retry() }
                }
            } else {
                if case .failed(let message) = model.phase {
                    Section {
                        Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Section {
                    Picker(AppStrings.Vault.host.swiftUIKey, selection: $model.hostID) {
                        Text(AppStrings.KeyExport.selectHost).tag(UUID?.none)
                        ForEach(model.hosts) { host in Text(host.name).tag(Optional(host.id)) }
                    }
                    if model.hosts.isEmpty { Text(AppStrings.KeyExport.noHosts).foregroundStyle(.secondary) }
                    LabeledContent(AppStrings.KeyExport.location.swiftUIKey) {
                        TextField(
                            AppStrings.KeyExport.location.swiftUIKey, text: $model.options.directory.singleLineText
                        ).labelsHidden().multilineTextAlignment(.trailing).singleLinePaste()
                    }
                    LabeledContent(AppStrings.KeyExport.filename.swiftUIKey) {
                        TextField(
                            AppStrings.KeyExport.filename.swiftUIKey, text: $model.options.filename.singleLineText
                        )
                        .labelsHidden().multilineTextAlignment(.trailing).singleLinePaste()
                    }
                }
                if model.needsExportPassphrase {
                    Section {
                        RevealableSecretField(AppStrings.Keychain.passphrase, text: $model.exportPassphrase)
                            .multilineTextAlignment(.leading)
                        Toggle(AppStrings.Keychain.savePassphrase.swiftUIKey, isOn: $model.saveExportPassphrase)
                        if let error = model.passphraseError { Text(error).font(.caption).foregroundStyle(.red) }
                    } footer: {
                        Text(AppStrings.KeyExport.passphraseHelp)
                    }
                }
                Section {
                    Text(AppStrings.KeyExport.scriptHelp).font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup(AppStrings.KeyExport.advanced.swiftUIKey, isExpanded: $advanced) {
                        scriptEditor
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
        #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
        #endif
    }

    private var scriptFont: Font {
        #if os(macOS)
            .caption.monospaced()
        #else
            .body.monospaced()
        #endif
    }

    private var scriptEditor: some View {
        TextEditor(text: $model.options.script)
            .autohidingScrollers()
            .font(scriptFont)
            .multilineTextAlignment(.leading)
            .frame(minHeight: 240)
            .scrollContentBackground(.hidden)
            .overlay(alignment: .topLeading) {
                if model.options.script.isEmpty {
                    Text(AppStrings.KeyExport.script)
                        .font(scriptFont)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(AppStrings.KeyExport.script.swiftUIKey)
    }
}
