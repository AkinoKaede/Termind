// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
