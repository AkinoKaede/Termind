import Foundation
import TermindDomain
import TermindPresentation
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

    @Test @MainActor
    func cancellingEditingOffersDiscardWhileNavigationStillOffersSave() async {
        let session = VaultWorkEditingSession()
        var commits = 0
        var transitions = 0
        var dirty = true
        session.register(
            route: .importKey, isDirty: { dirty },
            commit: {
                commits += 1
                return true
            })
        session.requestCancellation(route: .importKey) { transitions += 1 }
        #expect(session.confirmation == .discardChanges)
        #expect(session.confirmationID != nil)
        session.saveAndProceed()
        await Task.yield()
        #expect(commits == 0)
        #expect(transitions == 0)
        session.cancelTransition()
        #expect(transitions == 0)

        session.requestTransition(route: .importKey) { transitions += 1 }
        #expect(session.confirmation == .saveChanges)
        session.saveAndProceed()
        for _ in 0..<100 where transitions == 0 { await Task.yield() }
        #expect(commits == 1)
        #expect(transitions == 1)

        session.requestCancellation(route: .importKey) { transitions += 1 }
        session.discardAndProceed()
        #expect(commits == 1)
        #expect(transitions == 2)
        dirty = false
        session.requestCancellation(route: .importKey) { transitions += 1 }
        #expect(session.confirmationID == nil)
        #expect(transitions == 3)
    }

    @Test @MainActor
    func failedAsyncSaveKeepsTheEditorOpenAndAllowsRetry() async throws {
        let session = VaultWorkEditingSession()
        var transitions = 0
        var commits = 0
        var completion: CheckedContinuation<Bool, Never>?
        session.register(
            route: .generateKey, isDirty: { true },
            commit: {
                commits += 1
                return await withCheckedContinuation { completion = $0 }
            })
        session.requestTransition(route: .generateKey) { transitions += 1 }
        session.saveAndProceed()
        for _ in 0..<100 where completion == nil { await Task.yield() }
        let first = try #require(completion)
        session.saveAndProceed()
        session.requestTransition(route: .generateKey) { transitions += 10 }
        session.discardAndProceed()
        first.resume(returning: false)
        for _ in 0..<100 where session.confirmationID != nil { await Task.yield() }
        #expect(transitions == 0)
        #expect(commits == 1)

        completion = nil
        session.requestTransition(route: .generateKey) { transitions += 1 }
        session.saveAndProceed()
        for _ in 0..<100 where completion == nil { await Task.yield() }
        let retry = try #require(completion)
        #expect(transitions == 0)
        retry.resume(returning: true)
        for _ in 0..<100 where transitions == 0 { await Task.yield() }
        #expect(transitions == 1)
        #expect(commits == 2)
    }

    @Test @MainActor
    func anActiveEditorOperationBlocksDismissalUntilItFinishes() {
        let session = VaultWorkEditingSession()
        var busy = true
        var transitions = 0
        session.register(route: .importKey, isDirty: { true }, isBusy: { busy }, commit: { true })
        session.requestTransition(route: .importKey) { transitions += 1 }
        #expect(session.confirmationID == nil)
        #expect(transitions == 0)
        busy = false
        session.requestTransition(route: .importKey) { transitions += 1 }
        #expect(session.confirmationID != nil)
        session.cancelTransition()
        #expect(transitions == 0)
        session.requestTransition(route: .importKey) { transitions += 1 }
        session.discardAndProceed()
        #expect(transitions == 1)
    }
}
