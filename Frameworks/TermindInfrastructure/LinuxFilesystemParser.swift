// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated enum LinuxFilesystemParser {
    public static func parse(_ source: String) throws -> [MetricsFilesystem] {
        let parts = source.components(separatedBy: "__TERMIND_DF__\n")
        guard parts.count == 2 else { throw MetricsReadError.output }
        let pattern = try NSRegularExpression(pattern: #"^(.+?)\s+(\S+)\s+(\d+)\s+(\d+)\s+(-?\d+)\s+(\d+)%\s+(.+)$"#)
        var usage: [String: (Double, Double, Double)] = [:]
        for line in parts[1].split(separator: "\n").map(String.init) {
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                continue
            }
            func field(_ index: Int) -> String {
                Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
            }
            guard let total = Double(field(3)), let used = Double(field(4)), let percent = Double(field(6)),
                total > 0, total.isFinite, used.isFinite, percent.isFinite
            else { continue }
            usage[field(7)] = (used * 1024, total * 1024, min(100, percent))
        }
        var result: [MetricsFilesystem] = []
        var seen = Set<String>()
        for line in parts[0].split(separator: "\n") {
            let sections = line.components(separatedBy: " - ")
            guard sections.count == 2 else { continue }
            let before = sections[0].split(separator: " ")
            let after = sections[1].split(separator: " ")
            guard before.count >= 6, after.count >= 2 else { continue }
            let mount = unescape(String(before[4]))
            let device = unescape(String(after[1]))
            let root = unescape(String(before[3]))
            guard root == "/" || after[0] == "btrfs" || mount == "/" else { continue }
            guard device.hasPrefix("/dev/") || mount == "/", seen.insert(mount).inserted else { continue }
            let capacity = usage[mount]
            result.append(
                MetricsFilesystem(
                    mountPoint: mount, device: device, type: String(after[0]), blockID: String(before[2]),
                    used: capacity?.0, total: capacity?.1, usedPercent: capacity?.2
                ))
        }
        return result.sorted {
            if $0.mountPoint == "/" { return $1.mountPoint != "/" }
            if $1.mountPoint == "/" { return false }
            return $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending
        }
    }

    private static func unescape(_ text: String) -> String {
        // Decode mountinfo's octal escaping once, with backslash last.
        text.replacingOccurrences(of: #"\040"#, with: " ")
            .replacingOccurrences(of: #"\011"#, with: "\t")
            .replacingOccurrences(of: #"\012"#, with: "\n")
            .replacingOccurrences(of: #"\134"#, with: "\\")
    }
}
