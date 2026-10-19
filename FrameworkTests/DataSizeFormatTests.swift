import TermindPresentation
import Testing

@Suite
struct DataSizeFormatTests {
    @Test func unavailableMetricsStayUnavailable() {
        #expect(DataSizeFormat.bytes(Double.nan) == "—")
        #expect(DataSizeFormat.bytes(-1.0) == "—")
        #expect(DataSizeFormat.rate(nil) == "—")
    }
}
