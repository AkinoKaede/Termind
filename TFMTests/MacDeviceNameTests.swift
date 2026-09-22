import Foundation
import Testing

@testable import Termind

struct MacDeviceNameTests {
    @Test
    func kernelHostnameTakesPriorityOverFallback() {
        let hostname = UUID().uuidString
        #expect(
            MacDeviceName.resolved(
                kernelHostname: hostname,
                fallback: "fallback"
            ) == hostname
        )
    }

    @Test
    func unavailableOrEmptyKernelHostnameUsesFallback() {
        let fallback = UUID().uuidString
        #expect(MacDeviceName.resolved(kernelHostname: nil, fallback: fallback) == fallback)
        #expect(MacDeviceName.resolved(kernelHostname: "", fallback: fallback) == fallback)
        #expect(MacDeviceName.resolved(kernelHostname: " \n ", fallback: fallback) == fallback)
    }

    @Test
    func kernelHostnameIsReadable() throws {
        let hostname = try #require(MacDeviceName.kernelHostname())
        #expect(!hostname.isEmpty)
    }
}
