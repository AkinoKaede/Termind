import AppKit
import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

/// The floating capsule answers two questions with one rule: does it appear at
/// all, and what does it shrink to. Splitting them is how you get a capsule on
/// screen with nothing to collapse into, or a collapsed dot for a session that
/// is not there.
@Suite
struct StatusBarPresentationTests {
    /// The dot's colour is the whole reason this is the collapsed form, so it
    /// has to carry whatever the connection is actually doing.
    @Test
    func theCollapsedDotCarriesTheLiveStatus() {
        for status: ConnectionStatus in [
            .disconnected, .connecting, .connected, .reconnecting, .failed("refused"),
        ] {
            #expect(
                StatusBarPresentation.collapsedGlyph(
                    hasSessionContext: true, status: status, hasTransfers: false
                ) == .connection(status)
            )
        }
    }

    /// A transfer with no pane in front of it is the one case where the capsule
    /// is about something other than a session.
    @Test
    func transfersWithoutASessionCollapseToTheTransferGlyph() {
        let glyph = StatusBarPresentation.collapsedGlyph(
            hasSessionContext: false, status: .disconnected, hasTransfers: true
        )

        #expect(glyph == .transfers)
    }

    /// A transfer is a thing that is happening; the connection is the thing you
    /// are looking at.
    @Test
    func theConnectionWinsWhenBothAreThere() {
        let glyph = StatusBarPresentation.collapsedGlyph(
            hasSessionContext: true, status: .connected, hasTransfers: true
        )

        #expect(glyph == .connection(.connected))
    }

    /// Nothing to say means no capsule — not an empty one floating over the pane.
    @Test
    func nothingToSayShowsNoCapsule() {
        let glyph = StatusBarPresentation.collapsedGlyph(
            hasSessionContext: false, status: .disconnected, hasTransfers: false
        )

        #expect(glyph == nil)
    }

    @Test
    func transferDirectionSymbolsDifferentiateOneWayTransfersAndUseOneValidSharedSymbol() {
        let uploads = [
            transfer(direction: .upload, state: .running),
            transfer(direction: .upload, state: .running),
        ]

        let uploadSymbol = StatusBarTransferPresentation.runningDirectionSymbol(for: uploads)
        let downloads = [
            transfer(direction: .download, state: .running),
            transfer(direction: .download, state: .running),
        ]

        let downloadSymbol = StatusBarTransferPresentation.runningDirectionSymbol(for: downloads)
        let sharedSymbols = [
            StatusBarTransferPresentation.idleDirectionSymbol,
            StatusBarTransferPresentation.runningDirectionSymbol(for: [transfer(direction: .copy, state: .running)]),
            StatusBarTransferPresentation.runningDirectionSymbol(
                for: [transfer(direction: .upload, state: .running), transfer(direction: .download, state: .running)]),
        ]
        #expect(uploadSymbol != downloadSymbol)
        #expect(Set(sharedSymbols).count == 1)
        #expect(uploadSymbol == "arrow.up")
        #expect(downloadSymbol == "arrow.down")
        #expect(sharedSymbols == ["arrow.up.arrow.down", "arrow.up.arrow.down", "arrow.up.arrow.down"])
        #expect(
            ([uploadSymbol, downloadSymbol] + sharedSymbols).allSatisfy {
                NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil
            })
    }

    @Test
    func onlyRunningTransfersChooseTheDirectionSymbol() {
        let transfers = [
            transfer(direction: .upload, state: .running),
            transfer(direction: .download, state: .queued),
            transfer(direction: .download, state: .paused),
            transfer(direction: .download, state: .completed),
            transfer(direction: .download, state: .cancelled),
            transfer(direction: .download, state: .failed("Offline")),
        ]

        let runningSymbol = StatusBarTransferPresentation.runningDirectionSymbol(for: transfers)
        let inactiveSymbol = StatusBarTransferPresentation.runningDirectionSymbol(
            for: [transfer(direction: .download, state: .queued)])
        #expect(runningSymbol == "arrow.up")
        #expect(inactiveSymbol == "arrow.up.arrow.down")
        #expect(NSImage(systemSymbolName: runningSymbol, accessibilityDescription: nil) != nil)
        #expect(NSImage(systemSymbolName: inactiveSymbol, accessibilityDescription: nil) != nil)
    }

    private func transfer(
        direction: SFTPTransfer.Direction,
        state: SFTPTransfer.State,
        byteCount: Int64 = 0,
        transferredBytes: Int64 = 0
    ) -> SFTPTransfer {
        SFTPTransfer(
            direction: direction,
            localPath: "/tmp/file.txt",
            remotePath: "/srv/file.txt",
            byteCount: byteCount,
            transferredBytes: transferredBytes,
            state: state
        )
    }
}
