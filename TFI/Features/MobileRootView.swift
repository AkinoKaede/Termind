import SwiftUI
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

struct MobileRootView: View {
    let app: MobileAppModel
    @State private var selection: MobileDestination?

    var body: some View {
        NavigationSplitView {
            List(MobileDestination.allCases, selection: $selection) { destination in
                NavigationLink(value: destination) {
                    Label(destination.title, systemImage: destination.symbol)
                }
            }
            .navigationTitle("Termind")
        } detail: {
            if let selection {
                destination(selection)
                    .navigationTitle(selection.title)
            } else {
                ContentUnavailableView(
                    "Termind", systemImage: "terminal", description: Text("Select a section to begin."))
            }
        }
    }

    @ViewBuilder
    private func destination(_ destination: MobileDestination) -> some View {
        switch destination {
        case .hosts:
            MobileHostsView(repository: app.hosts)
        case .assistant:
            ContentUnavailableView(
                "Assistant", systemImage: "sparkles",
                description: Text("Assistant will be available in a future update."))
        case .settings:
            Form {
                LabeledContent(
                    "Version",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
            }
        }
    }
}

private struct MobileHostsView: View {
    let repository: any HostRepository
    @State private var snapshot = HostLibrarySnapshot.empty
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView("Unable to Load Hosts", systemImage: "exclamationmark.triangle")
            } else if snapshot.hosts.isEmpty {
                ContentUnavailableView(
                    "No Hosts", systemImage: "server.rack",
                    description: Text("Host management will be available in a future update."))
            } else {
                List(snapshot.hosts) { host in
                    VStack(alignment: .leading) {
                        Text(host.name)
                        Text(host.displayAddress).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            do {
                snapshot = try repository.snapshot().value
                for await change in repository.changes() {
                    guard !Task.isCancelled else { return }
                    snapshot = change.value
                }
            } catch {
                failed = true
            }
        }
    }
}

extension MobileDestination {
    fileprivate var title: String {
        switch self {
        case .hosts: String(localized: "Hosts")
        case .assistant: String(localized: "Assistant")
        case .settings: String(localized: "Settings")
        }
    }

    fileprivate var symbol: String {
        switch self {
        case .hosts: "server.rack"
        case .assistant: "sparkles"
        case .settings: "gearshape"
        }
    }
}
