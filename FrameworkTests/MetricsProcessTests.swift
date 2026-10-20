// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import TermindInfrastructure
import Testing

@Suite
struct MetricsProcessTests {
    @Test
    func procStatHandlesParenthesesAndUsesRemotePageSize() throws {
        let source = """
            cpu 100 0 0 900 0 0 0 0 0 0
            cpu0 50 0 0 450 0 0 0 0 0 0
            cpu1 50 0 0 450 0 0 0 0 0 0
            pagesize 4096
            __TERMIND_PROCESSES__
            \(stat(pid: 42, name: "worker (a)", user: 10, system: 5, started: 100, pages: 25))
            """
        let result = try LinuxProcessParser.parse(source)
        #expect(result.coreCount == 2)
        let process = try #require(result.processes.first)
        #expect(process.pid == 42 && process.name == "worker (a)")
        #expect(process.memory == 102_400.0)
        #expect(process.ticks == 15 && process.started == 100)
    }

    @Test
    func processCPUIsPerCoreAndPIDReuseDoesNotInheritCounters() {
        let previous = MetricsProcessSample(
            cpu: [100, 0, 0, 900, 0, 0, 0, 0], coreCount: 2,
            processes: [
                MetricsProcessCounter(pid: 1, name: "first", ticks: 10, started: 1),
                MetricsProcessCounter(pid: 2, name: "reused", ticks: 10, started: 1),
            ])
        let current = MetricsProcessSample(
            cpu: [200, 0, 0, 900, 0, 0, 0, 0], coreCount: 2,
            processes: [
                MetricsProcessCounter(pid: 2, name: "new", ticks: 200, started: 2),
                MetricsProcessCounter(pid: 1, name: "first", ticks: 85, started: 1),
            ])
        let rows = MetricsProcess.rows(previous: previous, current: current)
        #expect(rows.first?.pid == 1)
        #expect(rows.first?.cpu == 150)
        #expect(rows.last?.cpu == nil)
        #expect(MetricsProcess.rows(previous: nil, current: current).allSatisfy { $0.cpu == nil })
    }

    @Test
    func exitedMalformedAndUnreadableProcessesDoNotFailTheSnapshot() throws {
        let source = """
            cpu 1 0 0 10 0 0 0 0
            cpu0 1 0 0 10 0 0 0 0
            pagesize unknown
            __TERMIND_PROCESSES__
            invalid
            2 (gone) R
            \(stat(pid: 42, name: "valid", user: 1, system: 0, started: 1, pages: 3))
            """
        let sample = try LinuxProcessParser.parse(source)
        #expect(sample.processes.count == 1)
        #expect(sample.processes.first?.memory == nil)
        #expect(throws: MetricsReadError.self) { try LinuxProcessParser.parse("missing procfs") }
    }

    private func stat(pid: Int, name: String, user: Int, system: Int, started: Int, pages: Int) -> String {
        var fields = Array(repeating: "0", count: 22)
        fields[0] = "R"
        fields[11] = String(user)
        fields[12] = String(system)
        fields[19] = String(started)
        fields[21] = String(pages)
        return "\(pid) (\(name)) " + fields.joined(separator: " ")
    }
}
