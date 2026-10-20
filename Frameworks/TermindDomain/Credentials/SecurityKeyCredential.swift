// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A reference to a credential on a physical authenticator. Contains no private key.
public nonisolated struct SecurityKeyCredential: Codable, Hashable, Sendable {
    public static let relyingParty = "termind.akinokaede.com"
    public var credentialID: Data
    public var publicKeyX963: Data
    public enum UserVerification: String, Codable, CaseIterable, Sendable {
        case required, preferred, discouraged
    }
    public var userVerification: UserVerification
    public var requiresUserPresence: Bool

    public init(
        credentialID: Data, publicKeyX963: Data, userVerification: UserVerification = .preferred,
        requiresUserPresence: Bool = true
    ) {
        self.credentialID = credentialID
        self.publicKeyX963 = publicKeyX963
        self.userVerification = userVerification
        self.requiresUserPresence = requiresUserPresence
    }
}
