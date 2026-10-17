import Foundation
import TermindDomain
import Testing

@Suite
nonisolated struct MetricsCPUUsageTests {
    private let before: [UInt64] = [100, 0, 100, 800, 0, 0, 0, 0, 90, 0]
    private let after: [UInt64] = [120, 0, 110, 850, 15, 0, 0, 5, 110, 0]

    @Test func aggregateAndCoreShareCounterBreakdownWithoutCountingGuestTwice() {
        let point = MetricsCalculation.point(
            previous: MetricsSample(uptime: 100, cpu: before, cpuCores: [7: before]),
            current: MetricsSample(uptime: 102, cpu: after, cpuCores: [7: after]),
            selection: MetricsSelection(id: UUID()), date: .now)

        let expected = MetricsCPUUsage(utilization: 35, user: 20, system: 10, wait: 15, steal: 5, idle: 50)
        #expect(point.cpuUsage == expected)
        #expect(point.cpuCores == [MetricsCPUPoint(id: 7, usage: expected)])
    }

    @Test func newAndResetCoresRemainUnknownWithoutDiscardingAggregateUsage() {
        let point = MetricsCalculation.point(
            previous: MetricsSample(uptime: 100, cpu: before, cpuCores: [7: before]),
            current: MetricsSample(uptime: 102, cpu: after, cpuCores: [7: [UInt64](repeating: 0, count: 8), 2: after]),
            selection: MetricsSelection(id: UUID()), date: .now)

        #expect(point.cpu == 35)
        #expect(point.cpuCores == [MetricsCPUPoint(id: 2), MetricsCPUPoint(id: 7)])
    }
}
