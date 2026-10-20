// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData

/// V48 adds this device’s persisted hostname; V47 remains frozen.
public enum TermindSchemaV48TailscaleModels {
    @Model
    public final class PersistentTailscaleLocalState {
        @Attribute(.unique) public var groupID: UUID
        public var profileID: UUID
        public var hostname: String?
        public var peersData: Data
        public init(groupID: UUID, profileID: UUID, peersData: Data = Data(), hostname: String? = nil) {
            self.groupID = groupID
            self.profileID = profileID
            self.peersData = peersData
            self.hostname = hostname
        }
    }
}
