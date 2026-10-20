// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A deliberately narrow description of the remote operating environment.
///
/// Values originate on an untrusted SSH host and can be included in model
/// requests, so every field is accepted only when it fits a small ASCII token
/// grammar. Human-readable os-release fields are intentionally excluded.
public nonisolated struct RemoteSystemInfo: Hashable, Codable, Sendable {
    public var distributionID: String?
    public var distributionLikeIDs: [String]
    public var distributionVersion: String?
    public var kernelName: String?
    public var kernelRelease: String?
    public var architecture: String?

    public init(
        distributionID: String? = nil,
        distributionLikeIDs: [String] = [],
        distributionVersion: String? = nil,
        kernelName: String? = nil,
        kernelRelease: String? = nil,
        architecture: String? = nil
    ) {
        self.distributionID = RemoteSystemIdentifier.sanitized(distributionID)
        self.distributionLikeIDs = RemoteSystemIdentifier.normalizedList(distributionLikeIDs)
        self.distributionVersion = Self.sanitized(distributionVersion)
        self.kernelName = Self.sanitized(kernelName)
        self.kernelRelease = Self.sanitized(kernelRelease)
        self.architecture = Self.sanitized(architecture)
    }

    private enum CodingKeys: String, CodingKey {
        case distributionID, distributionLikeIDs, distributionVersion
        case kernelName, kernelRelease, architecture
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            distributionID: try container.decodeIfPresent(String.self, forKey: .distributionID),
            distributionLikeIDs: try container.decodeIfPresent(
                [String].self, forKey: .distributionLikeIDs
            ) ?? [],
            distributionVersion: try container.decodeIfPresent(
                String.self, forKey: .distributionVersion
            ),
            kernelName: try container.decodeIfPresent(String.self, forKey: .kernelName),
            kernelRelease: try container.decodeIfPresent(String.self, forKey: .kernelRelease),
            architecture: try container.decodeIfPresent(String.self, forKey: .architecture)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(distributionID, forKey: .distributionID)
        if !distributionLikeIDs.isEmpty {
            try container.encode(distributionLikeIDs, forKey: .distributionLikeIDs)
        }
        try container.encodeIfPresent(distributionVersion, forKey: .distributionVersion)
        try container.encodeIfPresent(kernelName, forKey: .kernelName)
        try container.encodeIfPresent(kernelRelease, forKey: .kernelRelease)
        try container.encodeIfPresent(architecture, forKey: .architecture)
    }

    /// Reads either the legacy `id|version|kernel_name|kernel_release|arch`
    /// line or the current `id|id_like|version|kernel_name|kernel_release|arch`
    /// line printed by the PTY bootstrap.
    ///
    /// Empty fields are meaningful (a BSD has no os-release), so the split keeps
    /// them rather than collapsing the run of separators.
    public init?(probeFields line: some StringProtocol) {
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5 || fields.count == 6 else { return nil }
        let values = fields.map { Self.unquoted(String($0)) }
        if values.count == 6 {
            self.init(
                distributionID: values[0],
                distributionLikeIDs: values[1].split(whereSeparator: \.isWhitespace).map(String.init),
                distributionVersion: values[2], kernelName: values[3],
                kernelRelease: values[4], architecture: values[5]
            )
        } else {
            self.init(
                distributionID: values[0], distributionVersion: values[1],
                kernelName: values[2], kernelRelease: values[3], architecture: values[4]
            )
        }
        if isEmpty { return nil }
    }

    public var isEmpty: Bool {
        distributionID == nil && distributionLikeIDs.isEmpty && distributionVersion == nil
            && kernelName == nil && kernelRelease == nil && architecture == nil
    }

    /// Reaches a model only after the validation above has made each value
    /// incapable of carrying prose or prompt instructions.
    ///
    /// Lines without a header, deliberately: `SessionContext.modelContext` owns
    /// the one fenced "data only" block these join, and a second preamble
    /// stacked on top of the first reads as boilerplate.
    public var factLines: [String] {
        var lines: [String] = []
        if let distributionID { lines.append("distribution_id: \(distributionID)") }
        if !distributionLikeIDs.isEmpty {
            lines.append("distribution_like_ids: \(distributionLikeIDs.joined(separator: " "))")
        }
        if let distributionVersion {
            lines.append("distribution_version: \(distributionVersion)")
        }
        if let kernelName { lines.append("kernel_name: \(kernelName)") }
        if let kernelRelease { lines.append("kernel_release: \(kernelRelease)") }
        if let architecture { lines.append("architecture: \(architecture)") }
        return lines
    }

    /// os-release quotes values that could contain spaces. Stripping a matched
    /// pair here rather than in `sanitized` keeps the ASCII-token grammar itself
    /// free of exceptions: `"22.04"` becomes `22.04`, while a lone quote stays
    /// and is rejected.
    private static func unquoted(_ raw: String) -> String {
        guard raw.count >= 2, let first = raw.first, let last = raw.last,
            first == last, first == "\"" || first == "'"
        else { return raw }
        return String(raw.dropFirst().dropLast())
    }

    private static func sanitized(_ proposed: String?) -> String? {
        RemoteSystemIdentifier.sanitized(proposed)
    }
}

public nonisolated enum RemoteDistributionDetection: Hashable, Sendable {
    case unavailable
    case resolved(DetectedDistribution?)
}

extension RemoteSystemInfo {
    public var distributionDetection: RemoteDistributionDetection {
        guard let kernelName else { return .unavailable }
        let kernel = kernelName.lowercased()
        if kernel == "darwin" {
            return .resolved(DetectedDistribution(id: "macos"))
        }
        if ["freebsd", "openbsd", "netbsd", "dragonfly"].contains(kernel) {
            return .resolved(DetectedDistribution(id: kernel))
        }
        guard kernel == "linux" else { return .resolved(nil) }
        return .resolved(DetectedDistribution(id: distributionID ?? "linux", likeIDs: distributionLikeIDs))
    }
}
