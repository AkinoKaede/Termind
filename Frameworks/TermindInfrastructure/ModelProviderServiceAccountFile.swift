import Foundation
import TermindApplication

public enum ModelProviderServiceAccountFile {
    public static func read(_ url: URL) async throws -> String {
        try await Task.detached {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try Task.checkCancellation()
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: ModelProviderServiceAccount.maximumBytes + 1) ?? Data()
            guard data.count <= ModelProviderServiceAccount.maximumBytes,
                let json = String(data: data, encoding: .utf8)
            else { throw ModelProviderServiceAccount.ValidationError.invalid }
            return try ModelProviderServiceAccount(json: json).json
        }.value
    }
}
