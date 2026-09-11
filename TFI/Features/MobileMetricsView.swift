import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileMetricsView: View {
    let app: MobileAppModel
    @State private var selecting = false
    @State private var selectedID: UUID?
    @State private var query = ""

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 12)], spacing: 12) {
                ForEach(app.metrics.servers.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) })
                { server in
                    Button {
                        selectedID = server.id
                    } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(server.name).font(.subheadline.bold()).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            MetricsInstrumentBody(server: server, sleeping: app.metrics.core.sleeping)
                        }
                        .padding(16).frame(maxWidth: .infinity)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
                        .contentShape(.rect)
                    }.buttonStyle(.plain)
                        .contextMenu {
                            Button(
                                server.selection.enabled ? "Pause" : "Resume",
                                systemImage: server.selection.enabled ? "pause" : "play"
                            ) {
                                app.metrics.core.setEnabled(!server.selection.enabled, for: server)
                            }
                            Button("Retry", systemImage: "arrow.clockwise") { app.metrics.core.retry(server) }
                            Button("Remove", role: .destructive) { app.metrics.remove(server.id) }
                        }
                }
            }.padding()
            if app.metrics.servers.isEmpty {
                ContentUnavailableView(
                    "No monitored servers", systemImage: "waveform.path.ecg",
                    description: Text("Add a saved Linux server to start monitoring."))
            }
        }
        .navigationTitle("Metrics")
        .searchable(text: $query)
        .toolbar { Button("Add Server", systemImage: "plus") { selecting = true } }
        .navigationDestination(item: $selectedID) { id in
            if let server = app.metrics.servers.first(where: { $0.id == id }) {
                MobileMetricsDetailView(app: app, server: server)
            }
        }
        .sheet(isPresented: $selecting) {
            NavigationStack {
                List(app.library.hosts) { host in
                    Button(host.name) {
                        selecting = false
                        if !app.metrics.add(host.id, pro: app.pro.hasProAccess) {
                            app.pro.presentPaywall(for: .unlimitedMetrics)
                        }
                    }
                }
                .navigationTitle("Hosts")
                .toolbar { Button("Cancel") { selecting = false } }
            }.presentationDetents([.medium, .large])
        }
        .task { app.metrics.start() }
    }
}

private struct MobileMetricsDetailView: View {
    let app: MobileAppModel
    let server: ServerMetric
    @State private var page = MobileMetricsDetailPage.status
    @State private var observer = UUID()
    @State private var availableWidth: CGFloat = 0
    @State private var query = ""

    var body: some View {
        Group {
            if server.showsConnectionJourney {
                MobileConnectionJourneyView(
                    journey: server.journey, library: app.library,
                    authenticationPrompt: server.authenticationPrompt, hostKey: server.hostKeyPrompt,
                    submit: { identity, username, password, passphrase, key, save in
                        app.metrics.core.submitAuthentication(
                            server, identityID: identity, username: username,
                            password: password, passphrase: passphrase, keyID: key, save: save)
                    },
                    accept: { remember in
                        if let observation = server.hostKey {
                            app.metrics.core.acceptHostKey(server, observation: observation, remember: remember)
                        }
                    }, retry: { app.metrics.core.retry(server) },
                    cancel: { app.metrics.core.setEnabled(false, for: server) })
            } else {
                GeometryReader { geometry in
                    if MobileMetricsDetailPage.showsBothColumns(width: geometry.size.width) {
                        HStack(alignment: .top, spacing: 16) {
                            ScrollView { MetricsSystemPanels(server: server).padding(1) }
                                .frame(width: min(360, geometry.size.width * 0.4))
                            MobileMetricsProcessesView(server: server, query: $query)
                        }.padding(16)
                    } else if page == .status {
                        ScrollView { MetricsSystemPanels(server: server).padding() }
                    } else {
                        MobileMetricsProcessesView(server: server, query: $query)
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            availableWidth = $0
        }
        .navigationTitle(server.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if !MobileMetricsDetailPage.showsBothColumns(width: availableWidth) {
                    Picker("Details", selection: $page) {
                        Image(systemName: "gauge.with.dots.needle.33percent").accessibilityLabel("Status").tag(
                            MobileMetricsDetailPage.status)
                        Image(systemName: "list.bullet.rectangle").accessibilityLabel("Processes").tag(
                            MobileMetricsDetailPage.processes)
                    }.pickerStyle(.segmented).frame(width: 104)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(server.selection.enabled ? "Pause" : "Resume") {
                        app.metrics.core.setEnabled(!server.selection.enabled, for: server)
                    }
                    Button("Retry") { app.metrics.core.retry(server) }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .onAppear { observe() }
        .onChange(of: server.showsConnectionJourney) { observe() }
        .onDisappear { app.metrics.core.stopObservingDetails(observer) }
    }

    private func observe() {
        if server.showsConnectionJourney {
            app.metrics.core.stopObservingDetails(observer)
        } else {
            app.metrics.core.observeDetails(hostID: server.id, observer: observer)
        }
    }
}

nonisolated enum MobileMetricsDetailPage: CaseIterable {
    case status, processes
    static func showsBothColumns(width: CGFloat) -> Bool { width >= 700 }
}

private struct MobileMetricsProcessesView: View {
    let server: ServerMetric
    @Binding var query: String
    @State private var sort = ProcessSort.cpu
    enum ProcessSort: String, CaseIterable { case cpu, memory, pid }
    private var rows: [MetricsProcess] {
        let filtered = server.processes.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)
        }
        return filtered.sorted {
            switch sort {
            case .cpu: ($0.cpu ?? -1) > ($1.cpu ?? -1)
            case .memory: ($0.memory ?? -1) > ($1.memory ?? -1)
            case .pid: $0.pid < $1.pid
            }
        }
    }
    var body: some View {
        List {
            Picker("Sort By", selection: $sort) {
                Text("CPU").tag(ProcessSort.cpu)
                Text("Memory").tag(ProcessSort.memory)
                Text("PID").tag(ProcessSort.pid)
            }
            if server.processesFailed { Text("Process metrics unavailable").foregroundStyle(.secondary) }
            ForEach(rows) { process in
                HStack {
                    Text(String(process.pid)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(
                        width: 48, alignment: .leading)
                    Text(process.name).lineLimit(1)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing) {
                        Text(MetricsFormat.percent(process.cpu))
                        Text(MetricsFormat.bytes(process.memory)).foregroundStyle(.secondary)
                    }.font(.caption.monospaced())
                }
            }
        }.searchable(text: $query)
    }
}
