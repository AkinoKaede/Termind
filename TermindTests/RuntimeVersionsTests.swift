import Testing

@testable import Termind

struct RuntimeVersionsTests {
    @Test
    func runtimeComponentsExposeVersions() {
        #expect(RuntimeVersions.ghostty != RuntimeVersions.unknown)
        #expect(!RuntimeVersions.ghostty.isEmpty)
        #expect(RuntimeVersions.libssh2 != RuntimeVersions.unknown)
        #expect(!RuntimeVersions.libssh2.isEmpty)
        #expect(RuntimeVersions.openSSL.split(separator: ".").count == 3)
    }

    @Test
    func missingVersionPointerFallsBackCleanly() {
        #expect(RuntimeVersions.decode(nil, length: 0) == nil)
    }
}
