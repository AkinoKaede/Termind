import Foundation

public nonisolated enum MetricsFormat {
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + "%"
    }
    public static func bytes(_ value: Double?) -> String {
        DataSizeFormat.bytes(value)
    }
    public static func rate(_ value: Double?) -> String { DataSizeFormat.rate(value) }
    public static func capacity(_ used: Double?, _ total: Double?) -> String { bytes(used) + " / " + bytes(total) }
}
