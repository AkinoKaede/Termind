import SwiftUI
import TermindApplication
import TermindPresentation

struct MetricsServerDetails: View {
    let server: ServerMetric
    var body: some View {
        VStack(spacing: 12) {
            MetricsConnectionNotice(server: server)
            MetricsSystemPanels(server: server)
        }
    }
}
