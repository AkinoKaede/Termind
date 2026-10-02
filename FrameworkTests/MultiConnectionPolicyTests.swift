import TermindDomain
import Testing

@Suite
nonisolated struct MultiConnectionPolicyTests {
    @Test(arguments: SFTPConcurrencyStrategy.allCases)
    func restrictingConnectionsPreservesSavedStrategyAndTransferLimits(_ strategy: SFTPConcurrencyStrategy) {
        let saved = SFTPPreferences(globalLimit: 80, perHostLimit: 40, strategy: strategy)
        let restricted = MultiConnectionPolicy(allowsMultipleConnections: false)
        #expect(
            restricted.sftpPreferences(saved)
                == SFTPPreferences(globalLimit: 80, perHostLimit: 40, strategy: .channelsOnly))
        #expect(restricted.forwardingConnections(8) == 1)
        #expect(saved.strategy == strategy)

        let enabled = MultiConnectionPolicy(allowsMultipleConnections: true)
        #expect(enabled.sftpPreferences(saved) == saved)
        #expect(enabled.forwardingConnections(8) == 8)
    }

    @Test(arguments: [-5, 0, 1, 8, 64, 100])
    func enabledForwardingStillEnforcesTransportLimits(_ saved: Int) {
        let policy = MultiConnectionPolicy(allowsMultipleConnections: true)
        let effective = policy.forwardingConnections(saved)
        #expect(Host.portForwardingMaxConnectionsRange.contains(effective))
        if Host.portForwardingMaxConnectionsRange.contains(saved) { #expect(effective == saved) }
    }
}
