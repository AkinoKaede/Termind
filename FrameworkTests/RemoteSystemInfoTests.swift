import TermindDomain
import Testing

@Suite("Remote system information")
struct RemoteSystemInfoTests {
    @Test func distributionDetectionDistinguishesUnknownLinuxFromANonLinuxHost() throws {
        #expect(RemoteSystemInfo().distributionDetection == .unavailable)
        #expect(
            RemoteSystemInfo(kernelName: "Linux").distributionDetection == .resolved(DetectedDistribution(id: "linux")))
        #expect(RemoteSystemInfo(kernelName: "SunOS").distributionDetection == .resolved(nil))

        let detected = try #require(DetectedDistribution(id: "Ubuntu", likeIDs: ["Debian"]))
        #expect(
            RemoteSystemInfo(
                distributionID: "Ubuntu",
                distributionLikeIDs: ["Debian"],
                kernelName: "linux"
            ).distributionDetection == .resolved(detected)
        )
    }

    @Test(arguments: ["FreeBSD", "OpenBSD", "NetBSD", "DragonFly"])
    func bsdDetectionUsesKernelRatherThanLinuxMetadata(kernel: String) {
        for spelling in [kernel, kernel.lowercased(), kernel.uppercased()] {
            let info = RemoteSystemInfo(distributionID: "ubuntu", kernelName: spelling)
            #expect(info.distributionDetection == .resolved(DetectedDistribution(id: kernel.lowercased())))
            #expect(info.distributionID == "ubuntu")
        }
        #expect(
            RemoteSystemInfo(kernelName: kernel).distributionDetection == .resolved(DetectedDistribution(id: kernel)))
    }
}
