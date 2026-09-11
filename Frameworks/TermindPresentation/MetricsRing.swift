import SwiftUI

public struct MetricsRing: View {
    public init(title: LocalizedStringKey, value: Double?) {
        self.title = title
        self.value = value
    }
    let title: LocalizedStringKey
    let value: Double?
    private var color: Color {
        guard let value else { return Color.secondary }
        return value >= 90 ? Color.red : value >= 75 ? Color.orange : Color.green
    }
    public var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 4)
                if let value {
                    Circle().trim(from: 0, to: min(1, max(0, value / 100)))
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(value.map { $0.formatted(.number.precision(.fractionLength(0))) + "%" } ?? "—")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }.frame(width: 40, height: 40)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(width: 46)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(MetricsFormat.percent(value))
    }
}
