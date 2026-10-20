// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// The character set used by text exchanged with a remote session.
public nonisolated enum RemoteCharset: String, Codable, CaseIterable, Identifiable, Sendable {
    case utf8
    case gb18030
    case big5
    case shiftJIS
    case eucJP
    case eucKR
    case isoLatin1
    case windows1252

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .gb18030: "GB18030"
        case .big5: "Big5"
        case .shiftJIS: "Shift_JIS"
        case .eucJP: "EUC-JP"
        case .eucKR: "EUC-KR"
        case .isoLatin1: "ISO-8859-1"
        case .windows1252: "Windows-1252"
        }
    }
}
