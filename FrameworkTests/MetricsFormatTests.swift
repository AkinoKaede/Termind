import Foundation
import TermindPresentation
import Testing

@Suite
struct MetricsFormatTests {
    @Test func memoryUsesBinaryScaling() {
        let gibibyte: Int64 = 1_073_741_824
        let expected = ByteCountFormatter.string(fromByteCount: gibibyte, countStyle: .binary)
        #expect(MetricsFormat.bytes(Double(gibibyte), style: .memory) == expected)
        #expect(MetricsFormat.bytes(Double(gibibyte), style: .memory) != MetricsFormat.bytes(Double(gibibyte)))
        #expect(
            MetricsFormat.capacity(Double(gibibyte), Double(gibibyte), style: .memory)
                == expected + " / " + expected)
    }

    @Test func trafficTotalsAndRatesUseDecimalScaling() {
        let megabyte: Int64 = 1_000_000
        let expected = ByteCountFormatter.string(fromByteCount: megabyte, countStyle: .decimal)
        #expect(MetricsFormat.bytes(Double(megabyte)) == expected)
        #expect(MetricsFormat.rate(Double(megabyte)) == expected + "/s")
        #expect(
            MetricsFormat.capacity(Double(megabyte), Double(megabyte), style: .decimal)
                == expected + " / " + expected)
    }

    @Test func filesystemCapacityUsesFileStyle() {
        let used: Int64 = 1_000_000_000
        let total: Int64 = 2_000_000_000
        let expectedUsed = ByteCountFormatter.string(fromByteCount: used, countStyle: .file)
        let expectedTotal = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        #expect(MetricsFormat.capacity(Double(used), Double(total)) == expectedUsed + " / " + expectedTotal)
    }

    @Test(arguments: [nil, -1, Double.nan, .infinity, -.infinity, Double(Int64.max)] as [Double?])
    func unavailableMetricsStayUnavailable(_ value: Double?) {
        #expect(MetricsFormat.bytes(value) == "—")
        #expect(MetricsFormat.bytes(value, style: .memory) == "—")
        #expect(MetricsFormat.rate(value) == "—")
        #expect(MetricsFormat.capacity(value, value) == "— / —")
    }

    @Test func zeroIsAvailableAndFractionalBytesAreRounded() {
        let zero = ByteCountFormatter.string(fromByteCount: 0, countStyle: .decimal)
        #expect(MetricsFormat.bytes(0) == zero)
        #expect(MetricsFormat.rate(0) == zero + "/s")
        #expect(MetricsFormat.bytes(999.6) == ByteCountFormatter.string(fromByteCount: 1000, countStyle: .decimal))
    }
}
