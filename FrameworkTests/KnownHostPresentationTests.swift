import TermindDomain
import TermindPresentation
import Testing

@Suite("Known Host presentation")
struct KnownHostPresentationTests {
    @Test func hashedEntriesHideTheirWireTokenFromTheCardTitle() {
        let hashed = KnownHostEntry(
            hostname: "|1|salt|hash",
            port: 22,
            algorithm: .ed25519,
            fingerprint: "SHA256:test"
        )
        let plain = KnownHostEntry(
            hostname: "example.invalid",
            port: 2222,
            algorithm: .ed25519,
            fingerprint: "SHA256:test"
        )

        #expect(hashed.presentationTitle == String(localized: "Hashed Address"))
        #expect(plain.presentationTitle == plain.displayAddress)
    }
}
