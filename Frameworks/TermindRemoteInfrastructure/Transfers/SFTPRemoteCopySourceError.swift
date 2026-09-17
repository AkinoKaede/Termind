import Foundation

nonisolated struct SFTPRemoteCopySourceError: LocalizedError {
    var path: String
    var errorDescription: String? {
        String(localized: "Unsupported or invalid SFTP copy source: \(path)")
    }
}
