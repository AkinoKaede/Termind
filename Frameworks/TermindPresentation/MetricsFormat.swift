// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum MetricsFormat {
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(1))) + "%"
    }
    public static func bytes(_ value: Double?, style: ByteCountFormatter.CountStyle = .decimal) -> String {
        guard let value, value.isFinite, value >= 0, let count = Int64(exactly: value.rounded()) else {
            return "—"
        }
        return ByteCountFormatter.string(fromByteCount: count, countStyle: style)
    }
    public static func rate(_ value: Double?) -> String {
        let formatted = bytes(value)
        return formatted == "—" ? formatted : formatted + "/s"
    }
    public static func capacity(
        _ used: Double?, _ total: Double?, style: ByteCountFormatter.CountStyle = .file
    ) -> String {
        bytes(used, style: style) + " / " + bytes(total, style: style)
    }
}
