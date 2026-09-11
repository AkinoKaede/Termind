import SwiftUI
import TermindApplication
import TermindDomain

/// A fixed label gutter followed by four equal-width, leading-aligned data columns.
public struct MetricsDiskTable: View {
    public init(io: MetricsDevicePoint?) { self.io = io }
    let io: MetricsDevicePoint?

    public var body: some View {
        GeometryReader { geometry in
            let columnWidth = max(0, (geometry.size.width - 30 - 4 * 8) / 4)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear.frame(height: 12)
                    Text("Disk Read Row").frame(height: 14)
                    Text("Disk Write Row").frame(height: 14)
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
                column(
                    "Speed", read: MetricsFormat.rate(io?.read), write: MetricsFormat.rate(io?.write),
                    width: columnWidth)
                column(
                    "Bytes", read: MetricsFormat.bytes(io?.readTotal), write: MetricsFormat.bytes(io?.writeTotal),
                    width: columnWidth)
                column("IOPS", read: number(io?.readIOPS), write: number(io?.writeIOPS), width: columnWidth)
                column("Wait", read: milliseconds(io?.readWait), write: milliseconds(io?.writeWait), width: columnWidth)
            }
        }
        .frame(height: 52)
        .frame(maxWidth: .infinity)
    }

    private func column(_ title: LocalizedStringKey, read: String, write: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: width, height: 12, alignment: .leading)
            Text(read).frame(width: width, height: 14, alignment: .leading)
            Text(write).frame(width: width, height: 14, alignment: .leading)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .lineLimit(1).minimumScaleFactor(0.65)
        .frame(width: width, alignment: .leading)
    }

    private func number(_ value: Double?) -> String {
        value?.formatted(.number.precision(.fractionLength(1))) ?? "—"
    }

    private func milliseconds(_ value: Double?) -> String {
        value.map { number($0) + " ms" } ?? "—"
    }
}
