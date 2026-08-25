import Foundation
import Testing

@testable import Termind

@Suite
struct RestrictedHTTPFetcherTests {
    @Test(arguments: [
        "http://127.0.0.1/", "http://10.0.0.1/", "http://169.254.169.254/",
        "http://[::1]/", "file:///etc/passwd", "http://user:pass@example.com/",
    ])
    func blocksPrivateSpecialAndCredentialedURLs(_ raw: String) async {
        guard let url = URL(string: raw) else {
            Issue.record("Invalid test URL")
            return
        }
        await #expect(throws: (any Error).self) {
            try await PublicAddressValidator.validate(url)
        }
    }
}
