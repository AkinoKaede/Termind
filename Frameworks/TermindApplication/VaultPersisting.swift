// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

@MainActor
public protocol VaultPersisting: AnyObject {
    func load() throws -> VaultSnapshot
    func save(_ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>) throws -> VaultMutationSet
    func modificationDates() throws -> [VaultRecordKey: Date]
}

extension VaultPersisting {
    public func modificationDates() throws -> [VaultRecordKey: Date] { [:] }
}
