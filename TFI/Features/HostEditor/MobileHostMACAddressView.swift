// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileHostMACAddressView: View {
    @State var model: HostMACAddressModel
    let library: HostLibraryModel
    let select: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if model.isFinished {
                    HostMACAddressCandidatesView(candidates: model.candidates) {
                        select($0.address.rawValue)
                        dismiss()
                    }
                } else {
                    MobileConnectionJourneyView(
                        journey: model.connection.journey, library: library,
                        authenticationPrompt: model.authenticationPrompt,
                        hostKey: model.connection.pendingHostKey, reconnectState: nil,
                        submit: { identity, username, password, passphrase, key, _ in
                            model.submit(
                                identityID: identity, username: username, password: password,
                                passphrase: passphrase, keyID: key)
                        },
                        accept: { _ in
                            if let prompt = model.connection.pendingHostKey { model.accept(prompt.observation) }
                        },
                        retry: model.start, retryReconnectNow: {}, stopReconnecting: {}, cancel: { dismiss() },
                        securityKeySigning: model.connection.securityKeySigning,
                        keyboardAuthentication: model.connection.keyboardAuthentication,
                        cancelKeyboardAuthentication: { dismiss() }, allowsPersistingHostKey: false)
                }
            }
            .navigationTitle(AppStrings.LocalNetwork.fetchMAC.swiftUIKey)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppStrings.Common.cancel.swiftUIKey, systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .task { model.start() }
        .onChange(of: model.isFinished) { _, finished in
            if finished, model.candidates.count == 1, let candidate = model.candidates.first {
                select(candidate.address.rawValue)
                dismiss()
            }
        }
        .onDisappear { model.cancel() }
    }
}
