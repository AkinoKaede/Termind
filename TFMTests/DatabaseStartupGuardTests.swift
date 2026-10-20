// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindPersistence
import Testing

@testable import Termind

@Suite @MainActor
struct DatabaseStartupGuardTests {
    @Test func permitsTheCurrentProcess() throws {
        try DatabaseStartupGuard.checkProcessIdentifiers([100], current: 100)
        try DatabaseStartupGuard.checkProcessIdentifiers([], current: 100)
    }

    @Test func refusesAnOlderInstanceEvenWhenItDoesNotImplementStoreLocking() {
        #expect(throws: PersistentStoreAccessError.inUse) {
            try DatabaseStartupGuard.checkProcessIdentifiers([100, 200], current: 100)
        }
    }
}
