import SwiftUI
import TermindApplication
import TermindPresentation

struct MetricsServerDetails: View {
    let server: ServerMetric
    let model: ServerMetricsModel
    var body: some View {
        VStack(spacing: 12) {
            MetricsConnectionNotice(server: server, model: model)
            MetricsSystemPanels(server: server)
        }
    }
}
