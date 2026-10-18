import Foundation
import Testing

@testable import Termind

@Suite @MainActor
struct SnippetEditorDirtyStateTests {
    @Test(arguments: [false, true])
    func packageEditsKeepTheCancellationRouteAndSupportReversion(existing: Bool) {
        let initialPackageID = UUID()
        var selection = SnippetEditorPackageSelection(snippetID: existing ? UUID() : nil, packageID: initialPackageID)
        let route = selection.editingRoute
        let session = VaultWorkEditingSession()
        var closed = false
        session.register(route: route, isDirty: { selection.isDirty }, commit: { false })
        session.requestCancellation(route: selection.editingRoute) { closed = true }
        #expect(closed && session.confirmationID == nil)

        for _ in 0..<2 {
            closed = false
            selection.value = nil
            session.requestCancellation(route: selection.editingRoute) { closed = true }
            #expect(!closed && session.confirmationID != nil)
            session.cancelTransition()
            selection.value = UUID()
            session.requestCancellation(route: selection.editingRoute) { closed = true }
            #expect(!closed && session.confirmationID != nil)
            session.cancelTransition()
            selection.value = initialPackageID
            session.requestCancellation(route: selection.editingRoute) { closed = true }
            #expect(closed && session.confirmationID == nil)
        }
    }
}
