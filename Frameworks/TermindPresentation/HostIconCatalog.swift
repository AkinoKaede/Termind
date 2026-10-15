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

    public var selectableEntries: [HostIconEntry] {
        let platforms = ["macos", "windows"].compactMap { id in entries.first { $0.id == id } }
        return platforms
            + entries.filter { $0.id != "macos" && $0.id != "windows" }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func entry(matching distribution: DetectedDistribution) -> HostIconEntry? {
        let byID = Dictionary(
            entries.flatMap { entry in entry.ids.map { ($0.lowercased(), entry) } },
            uniquingKeysWith: { first, _ in first }
        )
        if let exact = byID[distribution.id] { return exact }
        return distribution.likeIDs.lazy.compactMap { byID[$0] }.first
    }
}
