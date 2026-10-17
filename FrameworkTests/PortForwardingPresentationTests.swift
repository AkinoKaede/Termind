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

    @Test(arguments: [
        (PortForwardingRule.Kind.local, "Local Port"),
        (.dynamic, "Local Port"),
        (.remote, "Remote Port"),
    ])
    func portLabelNamesThePortThatKindForwards(
        _ kind: PortForwardingRule.Kind,
        _ resource: String
    ) {
        #expect(
            PortForwardingFieldPresentation.portLabel(for: kind).key
                == LocalizedStringResource(stringLiteral: resource).key)
    }

    @Test(arguments: [PortForwardingRule.Kind.local, .remote, .dynamic])
    func destinationFieldsFollowTheForwardingKind(_ kind: PortForwardingRule.Kind) {
        let expected: [String]
        switch kind {
        case .local:
            #expect(PortForwardingFieldPresentation.showsDestination(for: kind))
            expected = [localDeviceName, "SSH Host", "Destination"]
        case .remote:
            #expect(PortForwardingFieldPresentation.showsDestination(for: kind))
            expected = ["SSH Host", localDeviceName, "Destination"]
        case .dynamic:
            #expect(!PortForwardingFieldPresentation.showsDestination(for: kind))
            expected = ["SOCKS5", localDeviceName, "SSH Host", "Requested Destination"]
        }
        assertOrdered(
            expected,
            in: PortForwardingFieldPresentation.directionDescription(for: kind).key)
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
