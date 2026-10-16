import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct HostMACAddressView: View {
    @State var model: HostMACAddressModel
    let back: () -> Void
    let select: (String) -> Void

    var body: some View {
        VaultDetailScaffold(
            title: AppStrings.LocalNetwork.fetchMAC, symbol: "rectangle.connected.to.line.below", close: back,
            closeLabel: AppStrings.Common.back, closeSymbol: "chevron.backward"
        ) {
            VStack(spacing: 12) {
                if model.isFinished {
                    HostMACAddressCandidatesView(candidates: model.candidates) {
                        select($0.address.rawValue)
                    }
                } else {
                    ConnectionJourneyView(
                        journey: model.connection.journey, authenticationPrompt: model.authenticationPrompt,
                        hostKey: model.connection.pendingHostKey,
                        submitAuthentication: { identity, username, password, passphrase, key, _ in
                            model.submit(
                                identityID: identity, username: username, password: password,
                                passphrase: passphrase, keyID: key)
                        },
                        continueHostKey: model.accept, trustHostKey: model.accept,
                        denyHostKey: back, retry: model.start, cancel: back,
                        securityKeySigning: model.connection.securityKeySigning,
                        keyboardAuthentication: model.connection.keyboardAuthentication,
                        cancelKeyboardAuthentication: back, isEmbedded: true, allowsPersistingHostKey: false)
                }
            }
            .padding()
        } footer: {
            EmptyView()
        }
        .task { model.start() }
        .onChange(of: model.isFinished) { _, finished in
            if finished, model.candidates.count == 1, let candidate = model.candidates.first {
                select(candidate.address.rawValue)
            }
        }
        .onDisappear { model.cancel() }
    }
}
