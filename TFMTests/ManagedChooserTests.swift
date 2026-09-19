import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
@MainActor
struct ManagedChooserTests {
    @Test
    func singleSelectionTracksCursorAndReplacesSelection() {
        let chooser = ManagedChooserState<Int>(mode: .single)

        chooser.activate(2)
        chooser.activate(3)

        #expect(chooser.cursor == 3)
        #expect(chooser.selected == [3])
    }

    @Test
    func multipleSelectionSurvivesFiltering() {
        let chooser = ManagedChooserState<Int>(mode: .multiple)
        chooser.activate(1)
        chooser.query = "filtered"
        chooser.queryDidChange(visible: [2, 3], enabled: [2, 3])
        chooser.activate(2)

        #expect(chooser.selected == [1, 2])
        #expect(chooser.cursor == 2)
    }

    @Test
    func selectAllOnlyUsesVisibleEnabledResults() {
        let chooser = ManagedChooserState<Int>(mode: .multiple, selected: [9])

        chooser.toggleAll(visible: [1, 2, 3], enabled: [1, 3])
        #expect(chooser.selected == [1, 3, 9])
        chooser.toggleAll(visible: [1, 2, 3], enabled: [1, 3])
        #expect(chooser.selected == [9])
    }

    @Test
    func keyboardCursorStopsAtTheEnds() {
        let chooser = ManagedChooserState<Int>(mode: .multiple)

        chooser.moveCursor(by: 1, through: [1, 2, 3])
        chooser.moveCursor(by: 1, through: [1, 2, 3])
        chooser.moveCursor(by: 10, through: [1, 2, 3])
        #expect(chooser.cursor == 3)
        chooser.moveCursor(by: -10, through: [1, 2, 3])
        #expect(chooser.cursor == 1)
    }

    @Test
    func disabledResultsNeverBecomeTheFilteredCursor() {
        let chooser = ManagedChooserState<Int>(mode: .multiple)
        chooser.query = "match"

        chooser.queryDidChange(visible: [1, 2, 3], enabled: [2, 3])

        #expect(chooser.cursor == 2)
        #expect(chooser.selected.isEmpty)
    }

    @Test
    func connectionProtocolsRouteToMatchingSessionKinds() {
        #expect(HostConnectionProtocol.ssh.target == .sshSession)
        #expect(HostConnectionProtocol.sftp.target == .sftpSession)
    }

    @Test
    func connectAndBatchStartupChooseProtocolsWithExpectedSelectionModes() {
        #expect(HostChooserPurpose.connect.choosesConnectionProtocol)
        #expect(!HostChooserPurpose.connect.allowsMultiple)
        #expect(HostChooserPurpose.connect.activatesHostImmediately)

        #expect(HostChooserPurpose.batchStartup.choosesConnectionProtocol)
        #expect(HostChooserPurpose.batchStartup.allowsMultiple)
        #expect(!HostChooserPurpose.batchStartup.activatesHostImmediately)

        #expect(HostChooserPurpose.metrics.allowsMultiple)
        #expect(!HostChooserPurpose.metrics.activatesHostImmediately)

        let snippet = HostChooserPurpose.snippet(
            SnippetHostChooserRequest(snippetIDs: [], strategy: .overrideAllTargets)
        )
        #expect(snippet.allowsMultiple)
        #expect(!snippet.activatesHostImmediately)
    }

}
