import SwiftUI
import TermindDomain

struct MobileKnownHostsView: View {
    let app: MobileAppModel
    @State private var removing: KnownHostEntry?
    @State private var query = ""

    private var entries: [KnownHostEntry] { app.knownHosts.search(query) }

    init(app: MobileAppModel, initialQuery: String = "") {
        self.app = app
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        MobileCardPage {
            if app.knownHosts.entries.isEmpty {
                ContentUnavailableView("No Known Hosts", systemImage: "checkmark.shield")
            } else if entries.isEmpty {
                ContentUnavailableView.search(text: query)
            }
            MobileCardGrid {
                ForEach(entries) { entry in
                    MobileCard {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                MobileCardIcon(
                                    symbol: entry.isMismatched ? "exclamationmark.shield" : "checkmark.shield",
                                    tint: entry.isMismatched ? .orange : .green)
                                Text(entry.displayAddress).font(.headline).frame(
                                    maxWidth: .infinity, alignment: .leading)
                            }
                            if entry.isMismatched {
                                MobileCardChip(
                                    title: "Host key changed", symbol: "exclamationmark.triangle",
                                    tint: .orange)
                            }
                        }
                    }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) { removing = entry }
                    }
                }
            }
        }
        .searchable(text: $query)
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
