import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
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
    @Test
    func aSessionCollapsesToItsConnection() {
        let glyph = StatusBarPresentation.collapsedGlyph(
            hasSessionContext: true, status: .connected, hasTransfers: false
        )

        #expect(glyph == .connection(.connected))
    }

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

    /// Collapsing changes the capsule's width, never its height, so the command
    /// generator and the upload notices can reserve one constant. If the height
    /// ever moves, this is what says the clearance moved with it.
    @Test
    func bottomOverlaysClearTheCapsuleInBothStates() {
        #expect(
            Metrics.StatusBar.overlayClearance
                == Metrics.StatusBar.height + Metrics.StatusBar.floatingInset * 2
        )
        #expect(Metrics.StatusBar.overlayClearance > Metrics.StatusBar.height)
    }

    @Test
    @MainActor
    func transferGlyphKeepsTheSameSizeAcrossStates() throws {
        let running = transfer(
            direction: .upload,
            state: .running,
            byteCount: 100,
            transferredBytes: 50
        )
        let indeterminate = transfer(direction: .download, state: .running)
        let failed = transfer(direction: .download, state: .failed("Offline"))
        let completed = transfer(direction: .upload, state: .completed)

        for transfers in [[running], [indeterminate], [failed], [completed]] {
            let coordinator = SFTPTransferCoordinator(
                store: HostLibraryModel(sftpTransfers: transfers)
            )
            let renderer = ImageRenderer(
                content: TransferGlyph(summary: coordinator.summary, transfers: transfers)
            )
            let image = try #require(renderer.nsImage)

            #expect(
                image.size
                    == CGSize(width: TransferGlyph.size, height: TransferGlyph.size)
            )
        }
    }

    @Test
    func runningUploadsUseTheUploadSymbol() {
        let transfers = [
            transfer(direction: .upload, state: .running),
            transfer(direction: .upload, state: .running),
        ]

        #expect(StatusBarTransferPresentation.runningDirectionSymbol(for: transfers) == "arrow.up")
    }

    @Test
    func idleTransfersUseTheBidirectionalSymbolWithoutACircle() {
        #expect(StatusBarTransferPresentation.idleDirectionSymbol == "arrow.up.arrow.down")
    }

    @Test
    func runningDownloadsUseTheDownloadSymbol() {
        let transfers = [
            transfer(direction: .download, state: .running),
            transfer(direction: .download, state: .running),
        ]

        #expect(StatusBarTransferPresentation.runningDirectionSymbol(for: transfers) == "arrow.down")
    }

    @Test
    func copiesAndMixedDirectionsUseTheBidirectionalSymbol() {
        #expect(
            StatusBarTransferPresentation.runningDirectionSymbol(
                for: [transfer(direction: .copy, state: .running)]
            ) == "arrow.up.arrow.down"
        )
        #expect(
            StatusBarTransferPresentation.runningDirectionSymbol(
                for: [
                    transfer(direction: .upload, state: .running),
                    transfer(direction: .download, state: .running),
                ]
            ) == "arrow.up.arrow.down"
        )
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

        #expect(StatusBarTransferPresentation.runningDirectionSymbol(for: transfers) == "arrow.up")
        #expect(
            StatusBarTransferPresentation.runningDirectionSymbol(
                for: [transfer(direction: .download, state: .queued)]
            ) == "arrow.up.arrow.down"
        )
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
