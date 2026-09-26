import Foundation
import TermindDomain

import struct TermindDomain.Host

nonisolated extension SFTPTransfer {
    public var statusLabel: String {
        switch (direction, state) {
        case (.upload, .running): String(localized: "Uploading")
        case (.download, .running): String(localized: "Downloading")
        case (.upload, .completed): String(localized: "Uploaded")
        case (.download, .completed): String(localized: "Downloaded")
        case (.copy, .completed): String(localized: AppStrings.Common.copied)
        default: state.label
        }
    }

    /// Failure, throughput, or byte progress, in that order. The caller supplies
    /// its existing fallback when a transfer has no measurable progress yet.
    public var progressDetail: String? {
        if case .failed(let reason) = state { return reason }
        if bytesPerSecond > 0 { return DataSizeFormat.rate(bytesPerSecond) }
        guard byteCount > 0 else { return nil }
        return "\(DataSizeFormat.bytes(transferredBytes)) of \(DataSizeFormat.bytes(byteCount))"
    }

    /// Shows only remote endpoints, abbreviating each host's resolved home directory.
    public func routeLabel(hostName: (Host.ID) -> String?) -> String {
        func remote(_ hostID: Host.ID?, _ path: String, home: String?) -> String {
            let displayed = RemotePath.displayed(
                path, home: home.map(RemoteHomeResolutionState.resolved) ?? .unavailable)
            guard let hostID, let name = hostName(hostID) else { return displayed }
            return "\(name) · \(displayed)"
        }

        switch direction {
        case .upload:
            return remote(destinationHostID, remotePath, home: destinationHomeDirectory)
        case .download:
            return remote(sourceHostID, remotePath, home: sourceHomeDirectory)
        case .copy:
            let source = remote(sourceHostID, localPath, home: sourceHomeDirectory)
            let destination = remote(destinationHostID, remotePath, home: destinationHomeDirectory)
            return "\(source) → \(destination)"
        }
    }
}
