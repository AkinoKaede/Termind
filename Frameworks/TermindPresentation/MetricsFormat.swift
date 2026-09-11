import Foundation

public nonisolated enum MetricsFormat {
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + "%"
    }
    public static func bytes(_ value: Double?) -> String {
        guard var value, value.isFinite, value >= 0 else { return "—" }
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return value.formatted(.number.precision(.fractionLength(index == 0 ? 0 : 1))) + " " + units[index]
    }
    public static func rate(_ value: Double?) -> String { value == nil ? "—" : bytes(value) + "/s" }
    public static func capacity(_ used: Double?, _ total: Double?) -> String { bytes(used) + " / " + bytes(total) }
}
