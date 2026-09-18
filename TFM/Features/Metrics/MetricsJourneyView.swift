import SwiftUI
import TermindApplication

/// Metrics uses the same authentication and host-key decisions as SSH/SFTP,
/// without creating an interactive terminal or a second transport owner.
struct MetricsJourneyView: View {
    let server: ServerMetric
    let model: ServerMetricsModel
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    var body: some View {
        ConnectionJourneyView(
            journey: server.journey,
            authenticationPrompt: server.authenticationPrompt,
            hostKey: server.hostKeyPrompt,
            submitAuthentication: { identity, username, password, passphrase, key, save in
                model.submitAuthentication(
                    server, identityID: identity, username: username, password: password,
                    passphrase: passphrase, keyID: key, save: save
                )
            },
            continueHostKey: { model.acceptHostKey(server, observation: $0, remember: false) },
            trustHostKey: { model.acceptHostKey(server, observation: $0, remember: true) },
            denyHostKey: cancel,
            retry: { model.retry(server) },
            cancel: cancel,
            keyboardAuthentication: server.keyboardAuthentication,
            cancelKeyboardAuthentication: cancel
        )
        .environment(app)
    }

    private func cancel() {
        model.setEnabled(false, for: server)
        window.metricsHostID = nil
    }
}
