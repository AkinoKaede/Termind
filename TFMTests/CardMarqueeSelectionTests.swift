import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite
struct CardMarqueeSelectionTests {
    @Test
    func rectangleSupportsDraggingInEveryDirection() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)

        #expect(
            CardMarqueeSelectionResolver.rectangle(
                from: CGPoint(x: 10, y: 20), to: CGPoint(x: 40, y: 60)
            ) == expected
        )
        #expect(
            CardMarqueeSelectionResolver.rectangle(
                from: CGPoint(x: 40, y: 60), to: CGPoint(x: 10, y: 20)
            ) == expected
        )
    }

    @Test
    func intersectingCardsReplaceSelectionAndPartialOverlapCounts() {
        let frames = [
            "left": CGRect(x: 0, y: 0, width: 100, height: 80),
            "right": CGRect(x: 120, y: 0, width: 100, height: 80),
            "below": CGRect(x: 0, y: 100, width: 100, height: 80),
        ]

        let selection = CardMarqueeSelectionResolver.selection(
            intersecting: CGRect(x: 90, y: 10, width: 50, height: 40),
            cardFrames: frames,
            base: ["below"]
        )

        #expect(selection == ["left", "right"])
    }

    @Test
    func shiftMarqueeExtendsExistingSelection() {
        let selection = CardMarqueeSelectionResolver.selection(
            intersecting: CGRect(x: 120, y: 0, width: 30, height: 30),
            cardFrames: [
                "left": CGRect(x: 0, y: 0, width: 100, height: 80),
                "right": CGRect(x: 120, y: 0, width: 100, height: 80),
            ],
            base: ["left"],
            extendsSelection: true
        )

        #expect(selection == ["left", "right"])
    }

    @Test
    func onlyTrueCanvasSpaceCanStartSelection() {
        let cards = [CGRect(x: 10, y: 10, width: 100, height: 80)]
        let controls = [CGRect(x: 10, y: 110, width: 160, height: 30)]

        #expect(
            !CardMarqueeSelectionResolver.isBlank(
                CGPoint(x: 50, y: 50), cardFrames: cards, interactiveFrames: controls
            )
        )
        #expect(
            !CardMarqueeSelectionResolver.isBlank(
                CGPoint(x: 50, y: 120), cardFrames: cards, interactiveFrames: controls
            )
        )
        #expect(
            CardMarqueeSelectionResolver.isBlank(
                CGPoint(x: 200, y: 200), cardFrames: cards, interactiveFrames: controls
            )
        )
    }

    @Test @MainActor
    func vaultEditingSessionOffersSaveDiscardAndCancelForDirtyRoutes() async {
        let session = VaultWorkEditingSession()
        let firstID = UUID()
        let secondID = UUID()
        var commits: [UUID] = []
        var transitions: [UUID] = []
        var isDirty = false

        let firstToken = session.register(
            route: .forwardingEditor(firstID), isDirty: { isDirty },
            commit: {
                commits.append(firstID)
                return true
            })
        session.requestTransition(route: .forwardingEditor(firstID)) { transitions.append(firstID) }
        #expect(transitions == [firstID])
        #expect(commits.isEmpty)

        isDirty = true
        session.requestTransition(route: .forwardingEditor(firstID)) { transitions.append(firstID) }
        #expect(session.confirmationID != nil)
        session.cancelTransition()
        #expect(transitions == [firstID])

        session.requestTransition(route: .forwardingEditor(firstID)) { transitions.append(firstID) }
        session.discardAndProceed()
        #expect(transitions == [firstID, firstID])

        _ = session.register(
            route: .forwardingEditor(secondID), isDirty: { true },
            commit: {
                commits.append(secondID)
                return true
            })
        session.unregister(firstToken)
        session.requestTransition(route: .forwardingEditor(secondID)) { transitions.append(secondID) }
        session.saveAndProceed()
        for _ in 0..<20 where transitions.last != secondID { await Task.yield() }
        #expect(commits == [secondID])
        #expect(transitions.last == secondID)
    }
}
