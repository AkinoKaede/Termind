import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileTerminalUploadMenuTests {
    @Test(arguments: [false, true])
    func editingActionsFormTheFirstRowAndAutoFillStaysAfterUpload(selecting: Bool) throws {
        let pasteboard = UIPasteboard.general
        let savedItems = pasteboard.items
        defer { pasteboard.items = savedItems }
        let view = MobileTerminalView(frame: .zero)
        view.uploadFiles = {}
        let autoFill = UIMenu(title: "System AutoFill", identifier: .autoFill, children: [])

        for hasPaste in [false, true] {
            pasteboard.items = []
            if hasPaste { pasteboard.string = "menu test" }
            let items =
                selecting
                ? view.touchSelectionMenuItems(
                    for: .init(sourcePoint: .zero, selectedText: "selected", systemMenuItems: [autoFill]))
                : view.touchMenuItems(for: .init(sourcePoint: .zero, systemMenuItems: [autoFill]))
            #expect(items.count == 3)
            let editing = try #require(items.first as? UIMenu)
            #expect(editing.options.contains(.displayInline))
            #expect(editing.preferredElementSize == .medium)
            let actions = editing.children.compactMap { $0 as? UIAction }
            let expectedIDs =
                (selecting ? ["terminal.copy"] : [])
                + (hasPaste ? ["terminal.paste"] : [])
                + (selecting ? [] : ["terminal.select"])
                + ["terminal.selectAll"]
            #expect(actions.map(\.identifier.rawValue) == expectedIDs)
            #expect(actions.last?.title == String(localized: AppStrings.Common.selectAll))
            let upload = try #require(items[1] as? UIMenu)
            #expect(upload.title == String(localized: AppStrings.Terminal.uploadFile))
            let system = try #require(items[2] as? UIMenu)
            #expect(system.identifier == .autoFill)
            #expect(system.title == autoFill.title)
        }
    }

    @Test func missingSystemAndUploadMenusLeaveOnlyTheEditingGroup() throws {
        let view = MobileTerminalView(frame: .zero)
        let items = view.touchMenuItems(for: .init(sourcePoint: .zero))
        #expect(items.count == 1)
        let editing = try #require(items.first as? UIMenu)
        #expect(editing.options.contains(.displayInline))
        #expect(editing.children.contains { ($0 as? UIAction)?.identifier.rawValue == "terminal.select" })
    }

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
