import Foundation
import TermindDomain

public nonisolated struct LinuxDistributionIconEntry: Codable, Hashable, Sendable {
    public var title: String
    public var asset: String
    public var ids: [String]
    public var hex: String
}

public nonisolated struct LinuxDistributionIconCatalog: Codable, Sendable {
    public var entries: [LinuxDistributionIconEntry]

    private static let bundled: Self? = {
        guard
            let url = Bundle.main.url(
                forResource: "LinuxDistributionIcons", withExtension: "json"
            ), let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }()

    public static func entry(for distribution: DetectedDistribution?) -> LinuxDistributionIconEntry? {
        guard let distribution, let catalog = bundled else { return nil }
        return catalog.entry(matching: distribution)
    }

    public func entry(matching distribution: DetectedDistribution) -> LinuxDistributionIconEntry? {
        let byID = Dictionary(
            entries.flatMap { entry in entry.ids.map { ($0.lowercased(), entry) } },
            uniquingKeysWith: { first, _ in first }
        )
        if let exact = byID[distribution.id] { return exact }
        return distribution.likeIDs.lazy.compactMap { byID[$0] }.first
    }
}
