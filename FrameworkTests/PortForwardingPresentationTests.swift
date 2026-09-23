import Foundation
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
    func localAndDynamicForwardingUseTheLocalPortResource(_ kind: PortForwardingRule.Kind) {
        #expect(
            PortForwardingFieldPresentation.portLabel(for: kind).key
                == LocalizedStringResource("Local Port").key)
    }

    @Test func remoteForwardingUsesTheRemotePortResource() {
        #expect(
            PortForwardingFieldPresentation.portLabel(for: .remote).key
                == LocalizedStringResource("Remote Port").key)
    }

    @Test(arguments: [PortForwardingRule.Kind.local, .remote])
    func fixedDestinationsAreShownForLocalAndRemoteForwarding(_ kind: PortForwardingRule.Kind) {
        #expect(PortForwardingFieldPresentation.showsDestination(for: kind))

        let expected: [String]
        switch kind {
        case .local:
            expected = [localDeviceName, "SSH Host", "Destination"]
        case .remote:
            expected = ["SSH Host", localDeviceName, "Destination"]
        case .dynamic:
            Issue.record("Dynamic forwarding does not show a fixed destination.")
            return
        }
        assertOrdered(
            expected,
            in: PortForwardingFieldPresentation.directionDescription(for: kind).key)
    }

    @Test func dynamicForwardingOmitsFixedDestinationFields() {
        #expect(!PortForwardingFieldPresentation.showsDestination(for: .dynamic))
        assertOrdered(
            ["SOCKS5", localDeviceName, "SSH Host", "Requested Destination"],
            in: PortForwardingFieldPresentation.directionDescription(for: .dynamic).key)
    }

    private var localDeviceName: String {
        #if os(macOS)
            "This Mac"
        #else
            "This Device"
        #endif
    }

    private func assertOrdered(_ tokens: [String], in text: String) {
        var remaining = text[...]
        for token in tokens {
            let range = remaining.range(of: token)
            #expect(range != nil)
            if let range { remaining = remaining[range.upperBound...] }
        }
    }
}
