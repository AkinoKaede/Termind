import Foundation
import UniformTypeIdentifiers

/// A receiving app may edit its own copy. Bring an explicitly selected copy back
/// into the existing edit record without changing its remote path or baseline.
actor MobileSFTPEditedCopyImporter {
    enum Failure: LocalizedError {
        case differentFormat

        var errorDescription: String? {
            String(localized: "Choose an edited copy with the same file format as the original.")
        }
    }

    func stage(_ source: URL, matching original: URL) throws -> URL {
        let originalType = UTType(filenameExtension: original.pathExtension)
        let sourceType = UTType(filenameExtension: source.pathExtension)
        let sameFormat =
            if let originalType, let sourceType { originalType == sourceType } else {
                original.pathExtension.lowercased() == source.pathExtension.lowercased()
            }
        guard sameFormat else { throw Failure.differentFormat }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TermindEditedImports", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appending(path: original.lastPathComponent)
        do {
            var coordinationError: NSError?
            var copyError: (any Error)?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else {
                        throw CocoaError(.fileReadUnsupportedScheme)
                    }
                    try FileManager.default.copyItem(at: url, to: copy)
                } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError { throw error }
            return copy
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
