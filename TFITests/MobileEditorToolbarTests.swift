import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1",
        "Set TERMIND_MOBILE_UI_TESTS=1 and disable parallel testing for key-window integration tests"),
    .serialized)
@MainActor
struct MobileEditorToolbarTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func saveDisablesActionsUntilCompletionAndThenDismisses(language: String) async throws {
        let state = EditorState()
        try await withEditor(state, language: language) { _, navigation in
            let cancel = try #require(cancelButton(in: navigation))
            let save = try #require(saveButton(in: navigation))
            #expect(cancel.isEnabled)
            #expect(!save.isEnabled)
            state.canSave = true
            try await settle()
            let enabledSave = try #require(saveButton(in: navigation))
            #expect(enabledSave.isEnabled)
            try activate(enabledSave)
            try await settle()
            #expect(state.saveCount == 1)
            #expect(state.isPresented)
            #expect(cancelButton(in: navigation)?.isEnabled == false)
            #expect(saveButton(in: navigation)?.isEnabled == false)
            state.finishSave()
            try await settle()
            #expect(!state.isPresented)
        }
    }

    @Test func failedSaveKeepsTheDraftAndShowsAnError() async throws {
        let state = EditorState()
        state.canSave = true
        state.fails = true
        try await withEditor(state) { controller, navigation in
            try activate(#require(saveButton(in: navigation)))
            try await settle()
            state.finishSave()
            try await settle()
            #expect(state.isPresented)
            #expect(state.title == "Example")
            #expect(saveButton(in: navigation)?.isEnabled == true)
            _ = try #require(descendant(of: UIAlertController.self, in: controller))
        }
    }

    @Test func moreActionsRemainAvailableBesideSaveAndDisableDuringSave() async throws {
        let state = EditorState()
        state.canSave = true
        state.showsActions = true
        try await withEditor(state) { _, navigation in
            #expect(saveButton(in: navigation)?.isEnabled == true)
            let initialActions = try await moreActions(in: navigation)
            #expect(initialActions.count == 2)
            #expect(initialActions.allSatisfy { !$0.attributes.contains(.disabled) })
            #expect(initialActions.allSatisfy { !$0.title.isEmpty && $0.image != nil })

            try activate(#require(saveButton(in: navigation)))
            try await settle()
            let savingActions = try await moreActions(in: navigation)
            #expect(savingActions.count == 2)
            #expect(savingActions.allSatisfy { $0.attributes.contains(.disabled) })

            state.finishSave()
            try await settle()
            #expect(!state.isPresented)
        }
    }

    @Test(arguments: [false, true], ["en", "zh-Hans", "zh-Hant"])
    func cancelOnlyDismissesUnmodifiedDrafts(isDirty: Bool, language: String) async throws {
        let state = EditorState()
        state.isDirty = isDirty
        try await withEditor(state, language: language) { controller, navigation in
            try activate(#require(cancelButton(in: navigation)))
            try await settle()
            #expect(state.isPresented == isDirty)
            #expect(state.saveCount == 0)
            if isDirty {
                let alert = try #require(descendant(of: UIAlertController.self, in: controller))
                #expect(alert.preferredStyle == .actionSheet)
                #expect(alert.title?.isEmpty != false)
                let locale = Locale(identifier: language)
                #expect(
                    alert.message == AppLocalization.resolve(AppStrings.Common.discardChangesQuestion, locale: locale))
                let actions = alert.actions.filter { $0.style != .cancel }
                #expect(actions.count == 1)
                #expect(actions.first?.style == .destructive)
                #expect(
                    actions.first?.title == AppLocalization.resolve(AppStrings.Common.discardChanges, locale: locale))
                #expect(saveButton(in: navigation) != nil)
                #expect(state.cancelCount == 0)
                if let window = controller.view.window {
                    let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }
                    Attachment.record(data, named: "discard-confirmation-\(language).png")
                }
            }
        }
    }

    private func withEditor(
        _ state: EditorState, language: String = "en",
        check: (UIViewController, UINavigationController) async throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(
            rootView: EditorHost(state: state).environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            state.finishSave()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await settle()
        let navigation = try #require(descendant(of: UINavigationController.self, in: controller))
        try await check(controller, navigation)
    }

    private func accessibleName(_ button: UIBarButtonItem) -> String? {
        button.accessibilityLabel ?? button.title ?? button.customView?.accessibilityLabel
    }

    private func activate(_ button: UIBarButtonItem) throws {
        let action = try #require(button.action)
        #expect(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil))
    }

    private func cancelButton(in navigation: UINavigationController) -> UIBarButtonItem? {
        toolbarButton(namedOneOf: ["Cancel", "取消"], in: navigation)
    }

    private func saveButton(in navigation: UINavigationController) -> UIBarButtonItem? {
        toolbarButton(namedOneOf: ["Save", "保存", "儲存"], in: navigation)
    }

    private func moreButton(in navigation: UINavigationController) -> UIBarButtonItem? {
        toolbarButton(namedOneOf: ["More", "更多"], in: navigation)
    }

    private func moreActions(in navigation: UINavigationController) async throws -> [UIAction] {
        let page = try #require(navigation.topViewController)
        let menu: UIMenu
        if #available(iOS 27.0, *) {
            menu = UIMenu(children: [try #require(page.navigationItem.additionalOverflowItems)])
        } else {
            menu = try #require(moreButton(in: navigation)?.menu)
        }
        let button = UIButton(frame: CGRect(x: 100, y: 100, width: 44, height: 44))
        button.menu = menu
        button.showsMenuAsPrimaryAction = true
        page.view.addSubview(button)
        defer { button.removeFromSuperview() }
        button.performPrimaryAction()
        try await settle()
        let interaction = try #require(button.contextMenuInteraction)
        var actions: [UIAction] = []
        interaction.updateVisibleMenu { resolved in
            actions = menuActions(resolved)
            return resolved
        }
        interaction.dismissMenu()
        try await settle()
        return actions
    }

    private func menuActions(_ menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let submenu = element as? UIMenu { return menuActions(submenu) }
            return []
        }
    }

    private func toolbarButton(
        namedOneOf names: Set<String>, in navigation: UINavigationController
    ) -> UIBarButtonItem? {
        guard let item = navigation.topViewController?.navigationItem else { return nil }
        let buttons =
            item.leadingItemGroups.flatMap(\.barButtonItems)
            + item.trailingItemGroups.flatMap(\.barButtonItems)
            + (item.leftBarButtonItems ?? [])
            + (item.rightBarButtonItems ?? [])
        return buttons.first { button in
            accessibleName(button).map(names.contains) == true
        }
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(700)) }

    private func descendant<T: UIViewController>(of type: T.Type, in controller: UIViewController) -> T? {
        var pending = [controller]
        var visited = Set<ObjectIdentifier>()
        while let next = pending.popLast() {
            guard visited.insert(ObjectIdentifier(next)).inserted else { continue }
            if let result = next as? T { return result }
            pending.append(contentsOf: next.children)
            if let presented = next.presentedViewController { pending.append(presented) }
        }
        return nil
    }

}

@Observable @MainActor private final class EditorState {
    var isPresented = true
    var isDirty = true
    var canSave = false
    var fails = false
    var showsActions = false
    var title = "Example"
    var saveCount = 0
    var cancelCount = 0
    var pendingSave: CheckedContinuation<Void, Never>?

    func finishSave() {
        pendingSave?.resume()
        pendingSave = nil
    }
}

private struct EditorHost: View {
    @Bindable var state: EditorState
    private enum SaveFailure: Error { case expected }

    var body: some View {
        Color.clear.sheet(isPresented: $state.isPresented) {
            MobileEditorSheet(
                title: "Snippet", isDirty: state.isDirty, canSave: state.canSave,
                actions: state.showsActions
                    ? [
                        MobileEditorToolbarAction(
                            id: "export", title: "Export", systemImage: "square.and.arrow.up", perform: {}),
                        MobileEditorToolbarAction(
                            id: "delete", title: "Delete", systemImage: "trash", role: .destructive,
                            startsGroup: true, perform: {}),
                    ] : [],
                onCancel: { state.cancelCount += 1 },
                save: {
                    state.saveCount += 1
                    await withCheckedContinuation { state.pendingSave = $0 }
                    if state.fails { throw SaveFailure.expected }
                }
            ) {
                TextField("Title", text: $state.title)
            }
        }
    }
}
