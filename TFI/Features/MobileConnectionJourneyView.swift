import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileConnectionJourneyView: View {
    let journey: ConnectionJourney
    let library: HostLibraryModel
    let authenticationPrompt: SSHAuthenticationPrompt?
    let hostKey: SSHHostKeyPrompt?
    let submit: (UUID?, String, String?, String?, UUID?, Bool) -> Void
    let accept: (Bool) -> Void
    let retry: () -> Void
    let cancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill").font(.title).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading) {
                        Text(journey.destination?.name ?? String(localized: "SSH Connection")).font(.headline)
                        Text(journey.destination?.address ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(journey.showsLogs ? "Hide Logs" : "Show Logs") { journey.showsLogs.toggle() }
                        .font(.caption)
                }.padding(.horizontal)
                ConnectionJourneyRouteView(journey: journey)
                Group {
                    if journey.showsLogs {
                        Text(journey.plainTextLog).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let authenticationPrompt {
                        SharedSSHAuthenticationForm(
                            prompt: authenticationPrompt, submit: submit, cancel: cancel, library: library
                        )
                        .id(authenticationPrompt.id)
                    } else if let hostKey {
                        SharedSSHHostKeyConfirmationForm(
                            prompt: hostKey, displayAddress: hostKey.observation.hostname,
                            proceed: { accept(false) }, trust: { accept(true) }, deny: cancel)
                    } else if case .failed(let message) = journey.phase {
                        VStack(spacing: 16) {
                            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            HStack {
                                Button("Cancel", action: cancel)
                                Spacer()
                                Button("Retry", action: retry).buttonStyle(.borderedProminent)
                            }
                        }
                    } else if journey.phase == .succeeded {
                        Label("Connection ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        ProgressView("Establishing connection…")
                        Button("Cancel", action: cancel)
                    }
                }.padding(.horizontal)
            }.padding(.vertical, 20)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
