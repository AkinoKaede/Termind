import TermindDomain
import Testing

@testable import TermindPresentation

@Suite("Port forwarding presentation")
struct PortForwardingPresentationTests {
    @Test func hostPickerShowsOnlyTheSavedName() {
        let host = Host(name: "Production", host: "production.example.invalid")

        #expect(PortForwardingFieldPresentation.hostTitle(for: host) == "Production")
        #expect(!PortForwardingFieldPresentation.hostTitle(for: host).contains(host.displayAddress))
    }

    @Test(arguments: [PortForwardingRule.Kind.local, .dynamic])
    func localAndDynamicForwardingUseLocalPort(_ kind: PortForwardingRule.Kind) {
        #expect(PortForwardingFieldPresentation.portLabel(for: kind) == "Local Port")
    }

    @Test func remoteForwardingUsesRemotePort() {
        #expect(PortForwardingFieldPresentation.portLabel(for: .remote) == "Remote Port")
    }

    @Test(arguments: [PortForwardingRule.Kind.local, .remote])
    func fixedDestinationsAreShownForLocalAndRemoteForwarding(_ kind: PortForwardingRule.Kind) {
        #expect(PortForwardingFieldPresentation.showsDestination(for: kind))
        #expect(PortForwardingFieldPresentation.directionDescription(for: kind).contains("Destination"))
        #expect(!PortForwardingFieldPresentation.directionDescription(for: kind).contains("Target"))
        #expect(PortForwardingFieldPresentation.directionDescription(for: kind).contains(localDeviceName))
        #expect(!PortForwardingFieldPresentation.directionDescription(for: kind).contains(otherDeviceName))
    }

    @Test func dynamicForwardingUsesARequestedDestinationWithoutFixedDestinationFields() {
        #expect(!PortForwardingFieldPresentation.showsDestination(for: .dynamic))
        #expect(
            PortForwardingFieldPresentation.directionDescription(for: .dynamic)
                == "SOCKS5 on \(localDeviceName) → SSH Host → Requested Destination")
    }

    private var localDeviceName: String {
        #if os(macOS)
            "This Mac"
        #else
            "This Device"
        #endif
    }

    private var otherDeviceName: String {
        #if os(macOS)
            "This Device"
        #else
            "This Mac"
        #endif
    }
}
