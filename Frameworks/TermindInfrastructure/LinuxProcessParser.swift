// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated enum LinuxProcessParser {
    public static func parse(_ source: String) throws -> MetricsProcessSample {
        var cpu: [UInt64] = []
        var cores = 0
        var pageSize: Double?
        var readingProcesses = false
        var processes: [MetricsProcessCounter] = []
        var seen = Set<Int>()
        for line in source.split(separator: "\n") {
            if line == "__TERMIND_PROCESSES__" {
                readingProcesses = true
                continue
            }
            if line.hasPrefix("pagesize ") {
                pageSize = line.split(separator: " ").last.flatMap { Double($0) }
                continue
            }
            if !readingProcesses {
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.first == "cpu" {
                    cpu = fields.dropFirst().compactMap { UInt64($0) }
                } else if let key = fields.first, key.hasPrefix("cpu"), Int(key.dropFirst(3)) != nil {
                    cores += 1
                }
                continue
            }
            // comm is parenthesized and can contain spaces or closing parentheses.
            guard let left = line.firstIndex(of: "("), let right = line.lastIndex(of: ")"), left < right,
                let pid = Int(line[..<left].trimmingCharacters(in: .whitespaces)), seen.insert(pid).inserted
            else { continue }
            let fields = line[line.index(after: right)...].split(whereSeparator: \.isWhitespace)
            guard fields.count > 21, let user = UInt64(fields[11]), let system = UInt64(fields[12]),
                let started = UInt64(fields[19]), let pages = Double(fields[21]), pages.isFinite, pages >= 0,
                user <= UInt64.max - system
            else { continue }
            var memory: Double?
            if let pageSize, pageSize.isFinite, pageSize > 0, (pages * pageSize).isFinite { memory = pages * pageSize }
            processes.append(
                MetricsProcessCounter(
                    pid: pid, name: String(line[line.index(after: left)..<right]), ticks: user + system,
                    started: started, memory: memory
                ))
        }
        guard readingProcesses, cpu.count >= 8, cores > 0 else { throw MetricsReadError.output }
        return MetricsProcessSample(cpu: cpu, coreCount: cores, processes: processes)
    }
}
