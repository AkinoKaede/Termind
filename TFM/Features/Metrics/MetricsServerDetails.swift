// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindPresentation

struct MetricsServerDetails: View {
    let server: ServerMetric
    var body: some View {
        VStack(spacing: 12) {
            MetricsConnectionNotice(server: server)
            MetricsSystemPanels(server: server)
        }
    }
}
