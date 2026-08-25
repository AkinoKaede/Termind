import Foundation

/// A deliberately narrow description of the remote operating environment.
///
/// Values originate on an untrusted SSH host and can be included in model
/// requests, so every field is accepted only when it fits a small ASCII token
/// grammar. Human-readable os-release fields are intentionally excluded.
nonisolated struct RemoteSystemInfo: Hashable, Codable, Sendable {
    var distributionID: String?
    var distributionVersion: String?
    var kernelName: String?
    var kernelRelease: String?
    var architecture: String?

    init(
        distributionID: String? = nil,
        distributionVersion: String? = nil,
        kernelName: String? = nil,
        kernelRelease: String? = nil,
        architecture: String? = nil
    ) {
        self.distributionID = Self.sanitized(distributionID)
        self.distributionVersion = Self.sanitized(distributionVersion)
        self.kernelName = Self.sanitized(kernelName)
        self.kernelRelease = Self.sanitized(kernelRelease)
        self.architecture = Self.sanitized(architecture)
    }

    private enum CodingKeys: String, CodingKey {
        case distributionID, distributionVersion, kernelName, kernelRelease, architecture
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            distributionID: try container.decodeIfPresent(String.self, forKey: .distributionID),
            distributionVersion: try container.decodeIfPresent(
                String.self, forKey: .distributionVersion
            ),
            kernelName: try container.decodeIfPresent(String.self, forKey: .kernelName),
            kernelRelease: try container.decodeIfPresent(String.self, forKey: .kernelRelease),
            architecture: try container.decodeIfPresent(String.self, forKey: .architecture)
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(distributionID, forKey: .distributionID)
        try container.encodeIfPresent(distributionVersion, forKey: .distributionVersion)
        try container.encodeIfPresent(kernelName, forKey: .kernelName)
        try container.encodeIfPresent(kernelRelease, forKey: .kernelRelease)
        try container.encodeIfPresent(architecture, forKey: .architecture)
    }

    var isEmpty: Bool {
        distributionID == nil && distributionVersion == nil
            && kernelName == nil && kernelRelease == nil && architecture == nil
    }

    /// Reaches a model only after the validation above has made each value
    /// incapable of carrying prose or prompt instructions.
    ///
    /// Lines without a header, deliberately: `SessionContext.modelContext` owns
    /// the one fenced "data only" block these join, and a second preamble
    /// stacked on top of the first reads as boilerplate.
    var factLines: [String] {
        var lines: [String] = []
        if let distributionID { lines.append("distribution_id: \(distributionID)") }
        if let distributionVersion {
            lines.append("distribution_version: \(distributionVersion)")
        }
        if let kernelName { lines.append("kernel_name: \(kernelName)") }
        if let kernelRelease { lines.append("kernel_release: \(kernelRelease)") }
        if let architecture { lines.append("architecture: \(architecture)") }
        return lines
    }

    private static func sanitized(_ proposed: String?) -> String? {
        guard let proposed else { return nil }
        let value = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 64,
            value.unicodeScalars.allSatisfy({ scalar in
                switch scalar.value {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
                case 0x2B, 0x2D, 0x2E, 0x5F: true  // + - . _
                default: false
                }
            })
        else { return nil }
        return value
    }
}
