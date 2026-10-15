import TermindDomain
import Testing

@Suite("Remote system information")
struct RemoteSystemInfoTests {
    @Test func distributionDetectionDistinguishesUnknownLinuxFromANonLinuxHost() throws {
        #expect(RemoteSystemInfo().distributionDetection == .unavailable)
        #expect(RemoteSystemInfo(kernelName: "Linux").distributionDetection == .unavailable)
        #expect(RemoteSystemInfo(kernelName: "FreeBSD").distributionDetection == .resolved(nil))

        let detected = try #require(DetectedDistribution(id: "Ubuntu", likeIDs: ["Debian"]))
        #expect(
            RemoteSystemInfo(
                distributionID: "Ubuntu",
                distributionLikeIDs: ["Debian"],
                kernelName: "linux"
            ).distributionDetection == .resolved(detected)
        )
    }
}
