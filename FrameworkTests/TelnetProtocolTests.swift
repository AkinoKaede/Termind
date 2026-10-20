// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct TelnetProtocolTests {
    @Test
    func negotiationAndEscapedIACSurviveChunkBoundaries() {
        var parser = TelnetProtocolParser()
        let first = parser.consume(Data([255, 251]))
        #expect(first.applicationData.isEmpty)

        let second = parser.consume(Data([1, 65, 255, 255, 66]))
        #expect(second.reply == Data([255, 253, 1]))
        #expect(second.applicationData == Data([65, 255, 66]))
    }

    @Test
    func nawsIsEnabledAndEscapesFFBytes() {
        var parser = TelnetProtocolParser()
        let result = parser.consume(Data([255, 253, 31]))
        #expect(result.enabledNAWS)
        #expect(parser.nawsEnabled)
        #expect(result.reply == Data([255, 251, 31]))

        let size = parser.windowSize(columns: 255, rows: 24)
        #expect(size.range(of: Data([255, 255])) != nil)
    }

    @Test
    func terminalTypeSubnegotiationRepliesWithXterm() {
        var parser = TelnetProtocolParser()
        let result = parser.consume(Data([255, 250, 24, 1, 255, 240]))
        #expect(String(decoding: result.reply, as: UTF8.self).contains("xterm-256color"))
    }

    @Test
    func outboundNVTNormalizesLineEndingsWithoutDoublingCRLF() {
        #expect(TelnetProtocolParser.encodeNVT(Data("a\rb\nc\r\nd".utf8)) == Data("a\r\nb\r\nc\r\nd".utf8))
    }
}
