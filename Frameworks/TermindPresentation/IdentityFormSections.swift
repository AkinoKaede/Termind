// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain

/// Shared Identity field grouping. Secret loading and persistence remain owned by each app.
public struct IdentityFormSections: View {
    @Binding private var name: String
    @Binding private var username: String
    @Binding private var password: String
    @Binding private var passwordStorage: PasswordStorage
    @Binding private var keyID: SSHKeyRef.ID?
    @Binding private var colorTag: TagColor
    private let namePrompt: Text
    private let keys: [SSHKeyRef]
    private let showsName: Bool
    private let showsKey: Bool
    private let canEditPassword: Bool
    private let canEditPasswordStorage: Bool

    public init(
        name: Binding<String>, username: Binding<String>, password: Binding<String>,
        passwordStorage: Binding<PasswordStorage>, keyID: Binding<SSHKeyRef.ID?>,
        colorTag: Binding<TagColor>, namePrompt: Text, keys: [SSHKeyRef],
        showsName: Bool = true, showsKey: Bool = true,
        canEditPassword: Bool = true, canEditPasswordStorage: Bool = true
    ) {
        _name = name
        _username = username
        _password = password
        _passwordStorage = passwordStorage
        _keyID = keyID
        _colorTag = colorTag
        self.namePrompt = namePrompt
        self.keys = keys
        self.showsName = showsName
        self.showsKey = showsKey
        self.canEditPassword = canEditPassword
        self.canEditPasswordStorage = canEditPasswordStorage
    }

    public var body: some View {
        Section {
            if showsName {
                VaultNameField(text: $name, prompt: namePrompt)
            }
            VaultColorField(selection: $colorTag)
        }
        Section(AppStrings.Vault.identity.swiftUIKey) {
            LabeledContent(AppStrings.Vault.username.swiftUIKey) {
                TextField(AppStrings.Vault.username.swiftUIKey, text: $username.singleLineText, axis: .horizontal)
                    .singleLinePaste()
                    .lineLimit(1)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
            }
            Picker("Store Password in", selection: $passwordStorage) {
                ForEach(PasswordStorage.allCases) { storage in
                    #if os(iOS)
                        Label(
                            storage == .thisDevice
                                ? String(localized: AppStrings.Keychain.thisDevice) : storage.displayName,
                            systemImage: storage == .thisDevice ? "ipad.and.iphone" : storage.symbol
                        )
                        .tag(storage)
                    #else
                        Label(storage.displayName, systemImage: storage.symbol).tag(storage)
                    #endif
                }
            }
            .disabled(!canEditPasswordStorage)
            LabeledContent(AppStrings.Vault.password.swiftUIKey) {
                RevealableSecretField(
                    AppStrings.Vault.password, text: $password, prompt: Text(AppStrings.Common.optional)
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .disabled(!canEditPassword)
            }
            if showsKey {
                Picker(AppStrings.Vault.key.swiftUIKey, selection: $keyID) {
                    Text(AppStrings.Common.none).tag(SSHKeyRef.ID?.none)
                    if !keys.isEmpty {
                        Divider()
                    }
                    ForEach(keys) { key in
                        Text(key.label).tag(SSHKeyRef.ID?.some(key.id))
                    }
                }
            }
        }
    }
}
