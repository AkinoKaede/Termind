import AgentKit
import Foundation

/// One byte-size vocabulary for every Termind surface.
public nonisolated enum DataSizeFormat {
    public static func bytes(_ value: Int64) -> String {
        AgentByteCountFormatter.string(fromByteCount: value)
    }

    public static func bytes(_ value: Int) -> String {
        bytes(Int64(value))
    }

    public static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0, value <= Double(Int64.max) else {
            return "—"
        }
        return bytes(Int64(value.rounded()))
    }

    public static func rate(_ value: Int64) -> String {
        value < 0 ? "—" : bytes(value) + "/s"
    }

    public static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return bytes(value) + "/s"
    }
}
