// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated struct HostIconEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var asset: String
    public var ids: [String]
    public var hex: String
}

public nonisolated struct HostIconCatalog: Codable, Sendable {
    public var entries: [HostIconEntry]

    public static let bundled: Self = {
        guard
            let url = Bundle.main.url(
                forResource: "HostIcons", withExtension: "json"
            ), let data = try? Data(contentsOf: url)
        else { return Self(entries: []) }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self(entries: [])
    }()

    public static func entry(for distribution: DetectedDistribution?) -> HostIconEntry? {
        guard let distribution else { return nil }
        return bundled.entry(matching: distribution)
    }

    public static func resolvedEntry(for host: TermindDomain.Host?) -> HostIconEntry? {
        bundled.resolvedEntry(
            overrideID: host?.iconOverrideID, distribution: host?.detectedDistribution)
    }

    public func resolvedEntry(overrideID: String?, distribution: DetectedDistribution?) -> HostIconEntry? {
        if let overrideID { return entries.first { $0.id == overrideID } }
        return distribution.flatMap { entry(matching: $0) }
    }

    public static func resolvedArtwork(for host: TermindDomain.Host?) -> HostIconArtwork {
        bundled.resolvedArtwork(overrideID: host?.iconOverrideID, distribution: host?.detectedDistribution)
    }

    public func resolvedArtwork(overrideID: String?, distribution: DetectedDistribution?) -> HostIconArtwork {
        if let overrideID, let icon = HostGeneralIcon(rawValue: overrideID) {
            return .systemImage(icon.systemImageName)
        }
        if let entry = resolvedEntry(overrideID: overrideID, distribution: distribution) {
            return .asset(entry.asset)
        }
        return .systemImage(HostGeneralIcon.server.systemImageName)
    }

    public var selectableEntries: [HostIconEntry] {
        entries.sorted {
            let comparison = $0.title.compare(
                $1.title, options: [.caseInsensitive], locale: Locale(identifier: "en_US"))
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    public func entry(matching distribution: DetectedDistribution) -> HostIconEntry? {
        let byID = Dictionary(
            entries.flatMap { entry in entry.ids.map { ($0.lowercased(), entry) } },
            uniquingKeysWith: { first, _ in first }
        )
        if let exact = byID[distribution.id] { return exact }
        if let related = distribution.likeIDs.lazy.compactMap({ byID[$0] }).first { return related }
        // Detection only persists supported OS families; BSD and macOS match above.
        return byID["linux"]
    }
}
