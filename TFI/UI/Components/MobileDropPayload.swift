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
    private enum Representation {
        case fileURL
        case file(UTType)
        case image(String)
    }

    static func acceptsUpload(_ providers: [NSItemProvider]) -> Bool {
        accepts(providers, kinds: [.files], fileMode: .staged)
    }

    static func accepts(
        _ providers: [NSItemProvider],
        kinds: Set<MobileDropKind>,
        fileMode: MobileDropFileMode = .referenced
    ) -> Bool {
        providers.contains {
            representation(of: $0, kinds: kinds, fileMode: fileMode) != nil
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
                try Task.checkCancellation()
                switch representation(of: provider, kinds: kinds, fileMode: fileMode) {
                case .fileURL:
                    guard
                        let url = try await fileURL(
                            from: provider,
                            stagingRoot: payload.stagedRoot
                        ), url.isFileURL
                    else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    payload.fileURLs.append(url)
                case .file(let type):
                    if let root = payload.stagedRoot {
                        payload.fileURLs.append(try await fileRepresentation(from: provider, type: type, in: root))
                    }
                case .image(let identifier):
                    payload.images.append(try await data(from: provider, typeIdentifier: identifier))
                case nil:
                    break
                }
            } catch is CancellationError {
                break
            } catch {
                payload.failures.append(error.localizedDescription)
            }
        }
        if Task.isCancelled {
            payload.fileURLs = []
            payload.images = []
        }
        if payload.fileURLs.isEmpty, let stagedRoot = payload.stagedRoot {
            try? FileManager.default.removeItem(at: stagedRoot)
            payload.stagedRoot = nil
        }
        return payload
    }

    private static func representation(
        of provider: NSItemProvider, kinds: Set<MobileDropKind>, fileMode: MobileDropFileMode
    ) -> Representation? {
        if kinds.contains(.files), provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return .fileURL
        }
        // Assistant image attachments keep their image semantics, even when files are staged.
        if kinds.contains(.images), let identifier = provider.registeredTypeIdentifiers.first(where: isImageType) {
            return .image(identifier)
        }
        guard kinds.contains(.files), fileMode == .staged,
            !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        else { return nil }
        let named = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let inPlaceTypes = provider.registeredTypeIdentifiers(fileOptions: .openInPlace)
        let type = provider.registeredTypeIdentifiers.compactMap(UTType.init).first {
            if $0.conforms(to: .directory) { return true }
            guard $0.conforms(to: .data), !$0.conforms(to: .url) else { return false }
            // A text selection is terminal input. Files can advertise the same UTI,
            // but supply a filename or an in-place file representation.
            return !$0.conforms(to: .text) || named || inPlaceTypes.contains($0.identifier)
        }
        return type.map(Representation.file)
    }

    private static func isImageType(_ identifier: String) -> Bool {
        UTType(identifier)?.conforms(to: .image) == true
    }

    nonisolated private static func fileURL(
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
                    guard (url as URL).isFileURL else {
                        continuation.resume(throwing: CocoaError(.fileReadUnknown))
                        return
                    }
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

    nonisolated private static func fileRepresentation(
        from provider: NSItemProvider, type: UTType, in root: URL
    ) async throws -> URL {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                do {
                    guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                    let name = stagedName(suggestedName, source: url, type: type)
                    // UIKit deletes its temporary representation when this callback returns.
                    continuation.resume(returning: try stage(url, in: root, name: name))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func stagedName(_ suggestedName: String?, source: URL, type: UTType) -> String {
        var name = suggestedName.map { ($0 as NSString).lastPathComponent } ?? source.lastPathComponent
        if name.isEmpty || name == "." || name == ".." || name == "/" {
            name = source.lastPathComponent
        }
        if !type.conforms(to: .directory), (name as NSString).pathExtension.isEmpty,
            let fileExtension = type.preferredFilenameExtension
        {
            name += "." + fileExtension
        }
        return name
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

    nonisolated private static func stage(_ source: URL, in root: URL, name: String? = nil) throws -> URL {
        let itemRoot = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: itemRoot, withIntermediateDirectories: true)
        let destination = itemRoot.appending(path: name ?? source.lastPathComponent)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        do {
            var coordinationError: NSError?
            var copyResult: Result<Void, any Error> = .failure(CocoaError(.fileReadUnknown))
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) {
                coordinatedURL in
                copyResult = Result { try FileManager.default.copyItem(at: coordinatedURL, to: destination) }
            }
            if let coordinationError { throw coordinationError }
            try copyResult.get()
        } catch {
            try? FileManager.default.removeItem(at: itemRoot)
            throw error
        }
        return destination
    }

    nonisolated private static func data(
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
