import SwiftUI
import TermindDomain

public struct MetricsSummaryView: View {
    private let point: MetricsPoint
    public init(point: MetricsPoint) { self.point = point }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let cpu = point.cpu {
                LabeledContent("CPU", value: cpu.formatted(.number.precision(.fractionLength(1))) + "%")
                ProgressView(value: min(1, max(0, cpu / 100)))
            }
            if let memory = point.memory {
                LabeledContent("Memory", value: memory.formatted(.number.precision(.fractionLength(1))) + "%")
                ProgressView(value: min(1, max(0, memory / 100)))
            }
            LabeledContent("Updated", value: point.date.formatted(date: .omitted, time: .standard))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
