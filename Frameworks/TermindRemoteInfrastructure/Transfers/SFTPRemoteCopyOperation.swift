import AgentKit
import Foundation
import TermindApplication
import TermindDomain

/// An awaited copy independent of browser payloads and transfer UI lifetimes.
public nonisolated enum SFTPRemoteCopyOperation {
    public struct Outcome: Sendable {
        public var actualDestinationPath: String
        public var copiedFiles = 0
        public var createdDirectories = 0
        public var skippedItems = 0
        public var bytes: Int64 = 0
        public var totalBytes: Int64 = 0
        public var failedPath: String?
        public var error: String?
    }

    public static func run(
        sourcePath: String, destinationPath: String, sameHost: Bool,
        source: any SFTPChannelProtocol, destination: any SFTPChannelProtocol,
        policy: TransferConflictPolicy, cancellation: TransferCancellationToken,
        report: @escaping @Sendable (Outcome, SFTPProgress?) -> Void
    ) async -> Outcome {
        var outcome = Outcome(actualDestinationPath: destinationPath)
        var currentPath = sourcePath
        func checkCancellation() throws {
            try Task.checkCancellation()
            guard !cancellation.isCancelled else { throw SFTPError.cancelled }
        }
        func contains(_ path: String, in prefix: String) -> Bool {
            path == prefix || prefix == "/" || path.hasPrefix(prefix + "/")
        }
        func join(_ base: String, _ relative: String) -> String {
            base == "/" ? "/\(relative)" : base + "/" + relative
        }
        do {
            try checkCancellation()
            guard try AgentToolSupport.normalizeRemotePath(sourcePath) == sourcePath,
                try AgentToolSupport.normalizeRemotePath(destinationPath) == destinationPath
            else { throw SFTPError.operation(String(localized: "Invalid SFTP copy source path.")) }
            // LSTAT each ancestor so a link cannot alias a source tree into the destination.
            for (path, client) in [(sourcePath, source), (destinationPath, destination)] {
                var ancestor = ""
                for component in path.split(separator: "/").dropLast() {
                    try checkCancellation()
                    ancestor += "/" + component
                    currentPath = ancestor
                    guard try await client.attributes(at: ancestor)?.kind == .directory else {
                        throw SFTPRemoteCopySourceError(path: ancestor)
                    }
                }
            }
            currentPath = sourcePath
            guard let root = try await source.attributes(at: sourcePath) else {
                throw SFTPError.operation(String(localized: "The SFTP copy source does not exist: \(sourcePath)"))
            }
            guard root.path == sourcePath, sourcePath != "/",
                root.name == (sourcePath as NSString).lastPathComponent
            else {
                throw SFTPError.operation(String(localized: "Invalid SFTP copy source path."))
            }
            let rootTarget = join(destinationPath, root.name)
            outcome.actualDestinationPath = rootTarget
            guard
                !sameHost || (rootTarget != sourcePath && (!root.isDirectory || !contains(rootTarget, in: sourcePath)))
            else { throw SFTPError.operation(String(localized: "A path cannot be copied into itself.")) }
            currentPath = destinationPath
            guard try await destination.attributes(at: destinationPath)?.isDirectory == true else {
                throw SFTPError.operation(String(localized: "The SFTP copy destination must be an existing directory."))
            }
            currentPath = sourcePath
            let entries = try await SFTPRemoteCopyPlanner.manifest(
                files: [root], client: source, regularItemsOnly: true, cancellation: cancellation
            )
            for entry in entries where !entry.isDirectory {
                let (total, overflow) = outcome.totalBytes.addingReportingOverflow(entry.byteCount)
                guard !overflow else {
                    throw SFTPError.operation(String(localized: "The SFTP copy is too large to count."))
                }
                outcome.totalBytes = total
            }
            report(outcome, nil)
            var skipped: [String] = []
            var mappings: [(String, String)] = []
            for entry in entries {
                try checkCancellation()
                let original = join(destinationPath, entry.relativePath)
                if skipped.contains(where: { contains(original, in: $0) }) {
                    outcome.skippedItems += 1
                    continue
                }
                currentPath = entry.sourcePath
                guard let fresh = try await source.attributes(at: entry.sourcePath), fresh.kind == entry.kind,
                    entry.isDirectory || fresh.size == entry.byteCount
                else {
                    throw SFTPError.operation(String(localized: "The SFTP copy source changed: \(entry.sourcePath)"))
                }
                var target = original
                for mapping in mappings where contains(original, in: mapping.0) {
                    target = mapping.1 + original.dropFirst(mapping.0.count)
                    break
                }
                currentPath = target
                try checkCancellation()
                let existing = try await destination.attributes(at: target)
                if entry.isDirectory {
                    let resolution = try await SFTPRemoteConflictResolver.resolveDirectories(
                        [target], conflicts: existing != nil && existing?.isDirectory != true ? [target] : [],
                        policy: policy, client: destination
                    )
                    outcome.createdDirectories += resolution.created.count
                    if !resolution.skipped.isEmpty {
                        skipped.append(original)
                        outcome.skippedItems += 1
                    }
                    if let mapping = resolution.mappings.first {
                        // Most specific mapping wins, including remapped nested directories.
                        mappings.insert((original, mapping.1), at: 0)
                        if original == rootTarget { outcome.actualDestinationPath = mapping.1 }
                    }
                } else {
                    var overwrite = false
                    if let existing {
                        guard
                            let resolution = try await SFTPRemoteConflictResolver.resolveConflict(
                                path: target, conflictingTargetIsDirectory: existing.isDirectory,
                                policy: policy, client: destination
                            )
                        else {
                            outcome.skippedItems += 1
                            report(outcome, nil)
                            continue
                        }
                        target = resolution.path
                        overwrite = resolution.overwrite
                    }
                    currentPath = target
                    if original == rootTarget { outcome.actualDestinationPath = target }
                    let snapshot = outcome
                    try checkCancellation()
                    try await source.copyFile(
                        from: entry.sourcePath, to: target, on: destination,
                        byteCount: entry.byteCount, overwrite: overwrite, cancellation: cancellation
                    ) { progress in report(snapshot, progress) }
                    outcome.copiedFiles += 1
                    outcome.bytes += entry.byteCount
                }
                report(outcome, nil)
            }
        } catch {
            outcome.failedPath = (error as? SFTPRemoteCopySourceError)?.path ?? currentPath
            outcome.error = error.localizedDescription
        }
        return outcome
    }
}
