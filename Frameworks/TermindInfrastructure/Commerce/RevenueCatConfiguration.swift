// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

nonisolated struct RevenueCatConfiguration: Equatable, Sendable {
    let apiKey: String
    let entitlementID: String
    var isTestStore: Bool { apiKey.hasPrefix("test_") }

    init?(apiKey: String?, entitlementID: String?, allowsTestStore: Bool) {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let entitlement = entitlementID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !entitlement.isEmpty, !entitlement.contains("$("),
            key.hasPrefix("appl_") || (allowsTestStore && key.hasPrefix("test_")),
            let suffix = key.split(separator: "_", maxSplits: 1).last,
            !suffix.isEmpty, key.count > 5,
            key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        self.apiKey = key
        self.entitlementID = entitlement
    }

    static func bundled(in bundle: Bundle = .main) -> RevenueCatConfiguration? {
        #if DEBUG
            let allowsTestStore = true
        #else
            let allowsTestStore = false
        #endif
        return RevenueCatConfiguration(
            apiKey: bundle.object(forInfoDictionaryKey: "TermindRevenueCatAPIKey") as? String,
            entitlementID: bundle.object(forInfoDictionaryKey: "TermindRevenueCatEntitlementID") as? String,
            allowsTestStore: allowsTestStore)
    }
}
