import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileTerminalUploadMenuTests {
    @Test func menuUsesNativePhotoAndFileActionsAndTracksAvailability() throws {
        let view = MobileTerminalView(frame: .zero)
        #expect(view.uploadMenuItems().isEmpty)
        var available = false
        view.uploadFiles = {}
        view.uploadPhotos = {}
        view.canUploadFiles = { available }
        let disabled = try #require(view.uploadMenuItems().first as? UIMenu)
        #expect(disabled.title == String(localized: AppStrings.Terminal.uploadFile))
        #expect(disabled.children.compactMap { $0 as? UIAction }.allSatisfy { $0.attributes.contains(.disabled) })
        available = true
        let enabled = try #require(view.uploadMenuItems().first as? UIMenu)
        let actions = enabled.children.compactMap { $0 as? UIAction }
        #expect(
            actions.map(\.title) == [
                String(localized: AppStrings.Assistant.photos), String(localized: AppStrings.Assistant.files),
            ])
        #expect(actions.allSatisfy { !$0.attributes.contains(.disabled) })
    }
}
