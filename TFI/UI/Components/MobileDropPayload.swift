import Foundation
import UniformTypeIdentifiers

nonisolated enum MobileDropKind: Hashable, Sendable {
    case files
    case images
}

nonisolated enum MobileDropFileMode: Sendable {
    case referenced
    case staged
}

nonisolated struct MobileDropPayload: Sendable {
    var fileURLs: [URL] = []
    var images: [Data] = []
    var failures: [String] = []
    var stagedRoot: URL?
}

@MainActor
enum MobileDropPayloadLoader {
    static func accepts(
        _ providers: [NSItemProvider],
        kinds: Set<MobileDropKind>
    ) -> Bool {
        providers.contains { provider in
            if kinds.contains(.files),
                provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            {
                return true
            }
            return kinds.contains(.images)
                && provider.registeredTypeIdentifiers.contains(where: isImageType)
        }
    }

    static func load(
        _ providers: [NSItemProvider],
        kinds: Set<MobileDropKind>,
        fileMode: MobileDropFileMode = .referenced
    ) async -> MobileDropPayload {
        var payload = MobileDropPayload()
        if fileMode == .staged {
            do {
                payload.stagedRoot = try makeStagingRoot()
            } catch {
                payload.failures.append(error.localizedDescription)
                return payload
            }
        }
        for provider in providers {
            do {
                if kinds.contains(.files),
                    provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                {
                    guard
                        let url = try await fileURL(
                            from: provider,
                            stagingRoot: payload.stagedRoot
                        ), url.isFileURL
                    else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    payload.fileURLs.append(url)
                } else if kinds.contains(.images),
                    let identifier = provider.registeredTypeIdentifiers.first(where: isImageType)
                {
                    payload.images.append(try await data(from: provider, typeIdentifier: identifier))
                }
            } catch {
                payload.failures.append(error.localizedDescription)
            }
        }
        if payload.fileURLs.isEmpty, let stagedRoot = payload.stagedRoot {
            try? FileManager.default.removeItem(at: stagedRoot)
            payload.stagedRoot = nil
        }
        return payload
    }

    private static func isImageType(_ identifier: String) -> Bool {
        UTType(identifier)?.conforms(to: .image) == true
    }

    private static func fileURL(
        from provider: NSItemProvider,
        stagingRoot: URL?
    ) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: NSURL.self) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let url = item as? NSURL {
                    do {
                        continuation.resume(
                            returning: try stagingRoot.map {
                                try stage(url as URL, in: $0)
                            } ?? (url as URL)
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    private static func makeStagingRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appending(
            path: "TermindDropUploads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let expiration = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        for candidate in try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let modified = try? candidate.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if modified.map({ $0 < expiration }) == true {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
        let root = parent.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    nonisolated private static func stage(_ source: URL, in root: URL) throws -> URL {
        let itemRoot = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: itemRoot, withIntermediateDirectories: true)
        let destination = itemRoot.appending(path: source.lastPathComponent)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private static func data(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
                }
            }
        }
    }
}
