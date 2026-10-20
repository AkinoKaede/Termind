// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import TermindRemoteInfrastructure

struct SSHWireEncodingTests {
    @Test func nonnegativeMpintsMatchRFC4251WireValues() {
        // RFC 4251 section 5: zero is an empty string; positive high-bit values need a sign octet.
        let vectors: [(Data, Data)] = [
            (Data(), Data([0, 0, 0, 0])),
            (Data([0, 0]), Data([0, 0, 0, 0])),
            (Data([0, 0, 0x12, 0x34]), Data([0, 0, 0, 2, 0x12, 0x34])),
            (Data([0x7f]), Data([0, 0, 0, 1, 0x7f])),
            (Data([0x80]), Data([0, 0, 0, 2, 0, 0x80])),
            (Data([0, 0x9a, 0x37, 0x8f, 0x9b]), Data([0, 0, 0, 5, 0, 0x9a, 0x37, 0x8f, 0x9b])),
        ]
        for (integer, wire) in vectors { #expect(SSHWireEncoding.mpint(integer) == wire) }
    }
}
