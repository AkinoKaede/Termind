import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileKeyExportDetailView: View {
    let library: HostLibraryModel
    @State var model: KeyExportModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if model.journey.isPresented {
                journey
            } else {
                KeyExportForm(model: model)
            }
        }
        .navigationTitle(AppStrings.Keychain.exportToHost.swiftUIKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.didExport {
                    Button(AppStrings.Common.done.swiftUIKey) { dismiss() }
                } else if case .failed = model.phase, model.journey.isPresented {
                    Button(AppStrings.Common.edit.swiftUIKey) { model.editOptions() }
                } else if !model.journey.isPresented {
                    Button(AppStrings.KeyExport.exportAndAttach.swiftUIKey) { model.start() }
                        .disabled(!model.canStart)
                } else if model.phase == .exporting {
                    ProgressView().accessibilityLabel(AppStrings.KeyExport.exporting.swiftUIKey)
                }
            }
        }
        .onDisappear { model.cancel() }
    }

    private var journey: some View {
        let promptID = model.authenticationPrompt?.id
        let hostKey = model.connection.pendingHostKey
        let operationID = model.operationID
        return MobileConnectionJourneyView(
            journey: model.journey, library: library, authenticationPrompt: model.authenticationPrompt,
            hostKey: hostKey, reconnectState: nil,
            submit: { identity, username, password, passphrase, key, save in
                guard let promptID else { return }
                model.submitAuthentication(
                    promptID: promptID, identityID: identity, username: username, password: password,
                    passphrase: passphrase, keyID: key, save: save)
            },
            accept: { remember in
                guard let hostKey else { return }
                model.acceptHostKey(hostKey.observation, operationID: operationID, remember: remember)
            },
            retry: model.retry, retryReconnectNow: {}, stopReconnecting: {}, cancel: { dismiss() },
            securityKeySigning: model.connection.securityKeySigning,
            keyboardAuthentication: model.connection.keyboardAuthentication,
            cancelKeyboardAuthentication: { dismiss() })
    }
}
