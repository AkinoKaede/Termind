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
        #expect(PortForwardingFieldPresentation.portLabel(for: kind).key == "Local Port")
    }

    @Test func remoteForwardingUsesRemotePort() {
        #expect(PortForwardingFieldPresentation.portLabel(for: .remote).key == "Remote Port")
    }

    @Test(arguments: [PortForwardingRule.Kind.local, .remote])
    func fixedDestinationsAreShownForLocalAndRemoteForwarding(_ kind: PortForwardingRule.Kind) {
        #expect(PortForwardingFieldPresentation.showsDestination(for: kind))
        #expect(PortForwardingFieldPresentation.directionDescription(for: kind).key.contains("Destination"))
        #expect(!PortForwardingFieldPresentation.directionDescription(for: kind).key.contains("Target"))
        #expect(PortForwardingFieldPresentation.directionDescription(for: kind).key.contains(localDeviceName))
        #expect(!PortForwardingFieldPresentation.directionDescription(for: kind).key.contains(otherDeviceName))
    }

    @Test func dynamicForwardingUsesARequestedDestinationWithoutFixedDestinationFields() {
        #expect(!PortForwardingFieldPresentation.showsDestination(for: .dynamic))
        #expect(
            PortForwardingFieldPresentation.directionDescription(for: .dynamic).key
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
