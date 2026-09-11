import SwiftUI
import TermindPresentation

struct MobileMetricsView: View {
    let app: MobileAppModel
    @State private var selecting = false

    var body: some View {
        List {
            ForEach(app.metrics.selections) { selection in
                Section(app.library.host(selection.id)?.name ?? "") {
                    if let point = app.metrics.points[selection.id] {
                        MetricsSummaryView(point: point)
                    } else if let error = app.metrics.errors[selection.id] {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                    Button("Remove", role: .destructive) { app.metrics.remove(selection.id) }
                }
            }
        }
        .navigationTitle("Metrics")
        .toolbar { Button("Add", systemImage: "plus") { selecting = true } }
        .sheet(isPresented: $selecting) {
            NavigationStack {
                List(app.library.hosts) { host in
                    Button(host.name) {
                        selecting = false
                        if app.metrics.add(host.id, pro: app.pro.hasProAccess) {
                            app.metrics.start(hosts: app.library)
                        } else {
                            app.pro.presentPaywall(for: .unlimitedMetrics)
                        }
                    }
                }
                .navigationTitle("Hosts")
                .toolbar { Button("Cancel") { selecting = false } }
            }.presentationDetents([.medium, .large])
        }
        .task { app.metrics.start(hosts: app.library) }
    }
}
