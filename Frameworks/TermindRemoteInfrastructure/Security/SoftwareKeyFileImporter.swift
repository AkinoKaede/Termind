import Foundation

public nonisolated struct SoftwareKeyFileImportResult: Equatable, Sendable {
    public var privateKey: String?
    public var certificate: String?
    public var inferredName: String?
    public init(privateKey: String? = nil, certificate: String? = nil, inferredName: String? = nil) {
        self.privateKey = privateKey
        self.certificate = certificate
        self.inferredName = inferredName
    }
}

public nonisolated enum SoftwareKeyFileImporter {
    public static func shouldInferName(from currentName: String) -> Bool {
        currentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func read(
        urls: [URL], infersName: Bool
    ) throws -> SoftwareKeyFileImportResult {
        guard !urls.isEmpty else { return SoftwareKeyFileImportResult() }
        var result = SoftwareKeyFileImportResult()
        for url in urls {
            let text = try readText(at: url)
            if text.contains("PRIVATE KEY") {
                result.privateKey = text
                if infersName { result.inferredName = url.lastPathComponent }
            } else if text.contains("-cert-v01@openssh.com") {
                result.certificate = text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "Choose a private key or OpenSSH user certificate file."
                        )
                    ]
                )
            }
        }
        return result
    }

    public static func unexpectedFileError() -> CocoaError {
        CocoaError(
            .fileReadCorruptFile,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "Choose a private key or OpenSSH user certificate file."
                )
            ]
        )
    }

    private static func readText(at url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) <= 8 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
