import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite
struct RemoteConnectionURLTests {
    @Test
    func parsesSSHAndLegacyFingerprint() throws {
        let value = try RemoteConnectionURLParser.parse(
            #require(
                URL(
                    string:
                        "ssh://deploy;fingerprint=ssh-rsa-00-11-22-33-44-55-66-77-88-99-aa-bb-cc-dd-ee-ff@example.com:2222/ignored"
                ))
        )
        #expect(value.kind == .ssh)
        #expect(value.username == "deploy")
        #expect(value.host == "example.com")
        #expect(value.port == 2222)
        #expect(value.path == nil)
        #expect(value.hostKeyFingerprint?.algorithm == .rsa)
        #expect(
            value.hostKeyFingerprint?.legacyMD5
                == Data([
                    0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                    0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
                ]))
    }

    @Test
    func parsesSFTPDirectoryAndIgnoresUnknownParameters() throws {
        let value = try RemoteConnectionURLParser.parse(
            #require(URL(string: "sftp://user@[2001:db8::1]/~/Documents/report%20one;unknown=x,type=d"))
        )
        #expect(value.kind == .sftp)
        #expect(value.host == "2001:db8::1")
        #expect(value.port == 22)
        #expect(value.path == "/~/Documents/report one")
        #expect(value.sftpType == .directory)
    }

    @Test
    func parsesTelnetAdvisoryCredentials() throws {
        let value = try RemoteConnectionURLParser.parse(
            #require(URL(string: "telnet://operator:p%40ss@example.com:2323/"))
        )
        #expect(value.kind == .telnet)
        #expect(value.username == "operator")
        #expect(value.advisoryPassword == "p@ss")
        #expect(value.port == 2323)
    }

    @Test(arguments: [
        "ssh://user:password@example.com",
        "sftp://user:password@example.com/file",
        "ssh://example.com?command=uptime",
        "telnet://example.com/path",
        "ssh://example.com:0",
        "ssh://user;fingerprint=ssh-rsa-SHA256:abc@example.com",
        "sftp://example.com/file;type=a",
    ])
    func rejectsUnsupportedOrMalformedLinks(_ raw: String) {
        #expect(throws: (any Error).self) {
            try RemoteConnectionURLParser.parse(#require(URL(string: raw)))
        }
    }

    @Test
    func legacyFingerprintMatchesOnlyTheSameRSAKey() throws {
        let parsed = try RemoteConnectionURLParser.parse(
            #require(URL(string: "ssh://u;fingerprint=ssh-rsa-00-11-22-33-44-55-66-77-88-99-aa-bb-cc-dd-ee-ff@host"))
        )
        let fingerprint = try #require(parsed.hostKeyFingerprint)
        let matching = SSHHostKeyObservation(
            hostname: "host", port: 22, algorithm: .rsa, fingerprint: "SHA256:test",
            legacyMD5Fingerprint: fingerprint.legacyMD5)
        let different = SSHHostKeyObservation(
            hostname: "host", port: 22, algorithm: .rsa, fingerprint: "SHA256:test",
            legacyMD5Fingerprint: Data(repeating: 0xff, count: 16))
        #expect(fingerprint.matches(matching))
        #expect(!fingerprint.matches(different))
    }
}
