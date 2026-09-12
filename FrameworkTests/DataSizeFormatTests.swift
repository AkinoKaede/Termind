import TermindPresentation
import Testing

@Suite
struct DataSizeFormatTests {
    @Test func zeroHasNoUnitAndSizesUseDecimalFileUnits() {
        #expect(DataSizeFormat.bytes(0) == "0")
        #expect(DataSizeFormat.bytes(999).contains("999"))
        #expect(DataSizeFormat.bytes(1_000).contains("KB"))
        #expect(DataSizeFormat.bytes(1_000_000).contains("MB"))
    }

    @Test func unavailableMetricsStayUnavailable() {
        #expect(DataSizeFormat.bytes(Double.nan) == "—")
        #expect(DataSizeFormat.bytes(-1.0) == "—")
        #expect(DataSizeFormat.rate(nil) == "—")
    }
}
