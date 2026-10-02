import AppKit
import TermindPresentation
import Testing

@testable import Termind

@Suite @MainActor
struct TerminalContextMenuTests {
    @Test func uploadActionAppearsOnlyWhenBoundAndUsesLiveAvailability() throws {
        let view = TermindTerminalView(frame: .zero)
        let title = String(localized: AppStrings.Terminal.uploadFile)
        #expect(view.selectionContextMenu().item(withTitle: title) == nil)
        var available = false
        var requests = 0
        view.uploadFiles = { requests += 1 }
        view.canUploadFiles = { available }
        #expect(view.selectionContextMenu().item(withTitle: title)?.isEnabled == false)
        available = true
        let item = try #require(view.selectionContextMenu().item(withTitle: title))
        #expect(item.isEnabled)
        _ = view.perform(item.action, with: item)
        #expect(requests == 1)
        available = false
        _ = view.perform(item.action, with: item)
        #expect(requests == 1)
    }

    @Test func oldPaneTeardownCannotRemoveOrDisableTheReplacementUploadMenu() throws {
        let owner = PersistentTerminalViewOwner(write: { _, _ in }, resize: { _ in })
        let mount = TerminalMountView(frame: .zero)
        owner.mount(in: mount, state: owner.state, isVisible: false, requestsFocus: false)
        defer { owner.unmount(from: mount) }
        let view = try #require(mount.subviews.first as? TermindTerminalView)
        let oldBinding = owner.bindUpload(
            action: { Issue.record("Retired pane received upload") }, isAvailable: { true })
        var requests = 0
        let currentBinding = owner.bindUpload(action: { requests += 1 }, isAvailable: { true })

        owner.updateUploadAvailability(for: oldBinding, isAvailable: { false })
        #expect(!owner.unbindUpload(oldBinding))
        let title = String(localized: AppStrings.Terminal.uploadFile)
        let item = try #require(view.selectionContextMenu().item(withTitle: title))
        #expect(item.isEnabled)
        _ = view.perform(item.action, with: item)
        #expect(requests == 1)

        #expect(owner.unbindUpload(currentBinding))
        #expect(view.selectionContextMenu().item(withTitle: title) == nil)
    }

    @Test func defaultMenuValidatesPasteAndOptionBypassesAutomaticPaste() throws {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(
                uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(
                saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
        }
        let view = TermindTerminalView(frame: .zero)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        pasteboard.clearContents()
        let emptyMenu = try #require(view.menu(for: event))
        let pasteTitle = String(localized: AppStrings.Common.paste)
        #expect(emptyMenu.item(withTitle: pasteTitle)?.isEnabled == false)
        #expect(emptyMenu.items.contains { $0.action == #selector(view.selectAll(_:)) && $0.isEnabled })
        #expect(!emptyMenu.items.contains { $0.action == #selector(view.copy(_:)) })

        pasteboard.setString("echo hello", forType: .string)
        #expect(view.menu(for: event)?.item(withTitle: pasteTitle)?.isEnabled == true)
        view.pasteOnRightClick = true
        #expect(view.menu(for: event) == nil)
        let optionEvent = try #require(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: .zero, modifierFlags: .option, timestamp: 1,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(view.menu(for: optionEvent)?.item(withTitle: pasteTitle)?.isEnabled == true)
    }
}
