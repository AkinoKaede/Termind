import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileMetricsView: View {
    let app: MobileAppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var selecting = false
    @State private var selectedID: UUID?

    var body: some View {
        MobileCardPage {
            if app.metrics.servers.isEmpty {
                ContentUnavailableView(
                    "No monitored servers", systemImage: "waveform.path.ecg",
                    description: Text("Add a saved Linux server to start monitoring."))
            }
            MobileCardGrid {
                ForEach(app.metrics.servers) { server in
                    MobileActionCard {
                        selectedID = server.id
                    } content: {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(server.name).font(.subheadline.bold()).lineLimit(1)
                            MetricsInstrumentBody(
                                server: server, sleeping: app.metrics.core.sleeping,
                                layout: typeSize.isAccessibilitySize ? .adaptive : .horizontal)
                        }
                    } actions: {
                        Button(
                            server.selection.enabled ? "Pause" : "Resume",
                            systemImage: server.selection.enabled ? "pause" : "play"
                        ) {
                            app.metrics.core.setEnabled(!server.selection.enabled, for: server)
                        }
                        Button("Retry", systemImage: "arrow.clockwise") { app.metrics.core.retry(server) }
                        Button("Remove", systemImage: "trash", role: .destructive) { app.metrics.remove(server.id) }
                    }
                }
            }
        }
        .navigationTitle("Metrics")
        .toolbar { Button("Add Server", systemImage: "plus") { selecting = true }.labelStyle(.iconOnly) }
        .navigationDestination(item: $selectedID) { id in
            if let server = app.metrics.servers.first(where: { $0.id == id }) {
                MobileMetricsDetailView(app: app, server: server)
            }
        }
        .sheet(isPresented: $selecting) {
            NavigationStack {
                MobileHostPicker(
                    library: app.library,
                    title: "Add Server",
                    emptyDescription: "Add a saved Linux server to start monitoring.",
                    cancel: { selecting = false },
                    select: { host in
                        selecting = false
                        if !app.metrics.add(host.id, pro: app.pro.hasProAccess) {
                            if let error = app.metrics.core.storageError {
                                app.error = error
                            } else {
                                app.pro.presentPaywall(for: .unlimitedMetrics)
                            }
                        }
                    })
            }.mobileSheetPresentation(compact: true)
        }
        .task { app.metrics.start() }
    }
}

private struct MobileMetricsDetailView: View {
    let app: MobileAppModel
    let server: ServerMetric
    @Environment(\.dismiss) private var dismiss
    @State private var page = MobileMetricsDetailPage.status
    @State private var observer = UUID()
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        Group {
            if server.showsConnectionJourney {
                MobileConnectionJourneyView(
                    journey: server.journey, library: app.library,
                    authenticationPrompt: server.authenticationPrompt, hostKey: server.hostKeyPrompt,
                    reconnectState: nil,
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
                    retryReconnectNow: {}, stopReconnecting: {},
                    cancel: {
                        app.metrics.core.setEnabled(false, for: server)
                        dismiss()
                    })
            } else {
                GeometryReader { geometry in
                    if MobileMetricsDetailPage.showsBothColumns(width: geometry.size.width) {
                        HStack(alignment: .top, spacing: 16) {
                            ScrollView { MetricsSystemPanels(server: server).padding(1) }
                                .frame(width: min(360, geometry.size.width * 0.4))
                            MobileMetricsProcessesView(server: server)
                        }.padding(16)
                    } else if page == .status {
                        ScrollView { MetricsSystemPanels(server: server).padding() }
                    } else {
                        MobileMetricsProcessesView(server: server)
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
                    Button(
                        server.selection.enabled ? "Pause" : "Resume",
                        systemImage: server.selection.enabled ? "pause" : "play"
                    ) {
                        app.metrics.core.setEnabled(!server.selection.enabled, for: server)
                    }
                    Button("Retry", systemImage: "arrow.clockwise") { app.metrics.core.retry(server) }
                } label: {
                    MobileOverflowMenuLabel("Metrics")
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
    @State private var sort = ProcessSort.cpu
    enum ProcessSort: String, CaseIterable { case cpu, memory, pid }
    private var rows: [MetricsProcess] {
        server.processes.sorted {
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
                    Text(String(process.pid))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 64, alignment: .leading)
                        .layoutPriority(1)
                    Text(process.name).lineLimit(1)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing) {
                        Text(MetricsFormat.percent(process.cpu))
                        Text(MetricsFormat.bytes(process.memory)).foregroundStyle(.secondary)
                    }.font(.caption.monospaced())
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemBackground))
    }
}
