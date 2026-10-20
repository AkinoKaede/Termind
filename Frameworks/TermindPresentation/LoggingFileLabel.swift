// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftUI
import TermindApplication

public struct LoggingFileLabel: View {
    private let file: ApplicationLogFile
    private let dateFormat: Date.FormatStyle

    public init(file: ApplicationLogFile, dateFormat: Date.FormatStyle) {
        self.file = file
        self.dateFormat = dateFormat
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(file.createdAt, format: dateFormat)
                    if file.isCurrent {
                        Text(AppStrings.Common.current).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(ByteCountFormatter.string(fromByteCount: file.byteCount, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "square.and.arrow.up").foregroundStyle(.secondary)
        }
    }
}
