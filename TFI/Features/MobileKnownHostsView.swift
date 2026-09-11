import SwiftUI
import TermindDomain

struct MobileKnownHostsView: View {
    let app: MobileAppModel
    @State private var removing: KnownHostEntry?

    var body: some View {
        List(app.knownHosts.entries) { entry in
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    entry.displayAddress,
                    systemImage: entry.isMismatched ? "exclamationmark.shield" : "checkmark.shield")
                Text(entry.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
            }
            .swipeActions { Button("Delete", role: .destructive) { removing = entry } }
        }
        .navigationTitle("Known Hosts")
        .confirmationDialog(
            "Delete Known Host?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = removing { _ = app.knownHosts.delete([entry.id]) }
                removing = nil
            }
        }
    }
}
