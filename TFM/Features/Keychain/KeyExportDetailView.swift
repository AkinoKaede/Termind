import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct KeyExportDetailView: View {
    let keyID: SSHKeyRef.ID
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @State private var model: KeyExportModel?

    var body: some View {
        VaultDetailScaffold(
            title: AppStrings.Keychain.exportToHost, symbol: "square.and.arrow.up", close: window.closeVaultWork
        ) {
            if let model {
                if model.journey.isPresented {
                    journey(model)
                } else {
                    KeyExportForm(model: model)
                }
            } else {
                ContentUnavailableView(AppStrings.Keychain.keyUnavailable.swiftUIKey, systemImage: "key.slash")
            }
        } footer: {
            HStack {
                if model?.phase == .exporting {
                    ProgressView().controlSize(.small)
                    Text(AppStrings.KeyExport.exporting).font(.caption)
                }
                Spacer()
                Button(
                    model?.didExport == true ? AppStrings.Common.done.swiftUIKey : AppStrings.Common.cancel.swiftUIKey,
                    action: window.closeVaultWork)
                if let model, case .failed = model.phase, model.journey.isPresented {
                    Button(AppStrings.Common.edit.swiftUIKey) { model.editOptions() }
                }
                if let model, !model.didExport, !model.journey.isPresented {
                    Button(AppStrings.KeyExport.exportAndAttach.swiftUIKey) { model.start() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!model.canStart)
                }
            }.padding(Metrics.Space.l)
        }
        .task(id: keyID) {
            model?.cancel()
            model = app.hostLibrary.key(keyID).map {
                KeyExportModel(key: $0, library: app.hostLibrary, services: app.connections.keyExportServices())
            }
        }
        .onDisappear { model?.cancel() }
    }

    private func journey(_ model: KeyExportModel) -> some View {
        let promptID = model.authenticationPrompt?.id
        let operationID = model.operationID
        return ConnectionJourneyView(
            journey: model.journey, authenticationPrompt: model.authenticationPrompt,
            hostKey: model.connection.pendingHostKey,
            submitAuthentication: { identity, username, password, passphrase, key, save in
                guard let promptID else { return }
                model.submitAuthentication(
                    promptID: promptID, identityID: identity, username: username, password: password,
                    passphrase: passphrase, keyID: key, save: save)
            },
            continueHostKey: { model.acceptHostKey($0, operationID: operationID, remember: false) },
            trustHostKey: { model.acceptHostKey($0, operationID: operationID, remember: true) },
            denyHostKey: window.closeVaultWork, retry: model.retry, cancel: window.closeVaultWork,
            securityKeySigning: model.connection.securityKeySigning,
            keyboardAuthentication: model.connection.keyboardAuthentication,
            cancelKeyboardAuthentication: window.closeVaultWork, isEmbedded: true)
    }
}
