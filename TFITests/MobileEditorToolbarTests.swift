import Foundation
import SwiftUI
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileEditorToolbarTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func iconButtonsKeepTheirNamesAndSaveLifecycle(language: String) async throws {
        let state = EditorState()
        try await withEditor(state, language: language) { _, navigation in
            let cancel = try #require(cancelButton(in: navigation))
            let save = try #require(saveButton(in: navigation))
            #expect(accessibleName(cancel) == (language == "en" ? "Cancel" : "取消"))
            let expectedSave =
                switch language {
                case "zh-Hans": "保存"
                case "zh-Hant": "儲存"
                default: "Save"
                }
            #expect(accessibleName(save) == expectedSave)
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
            let alert = try #require(descendant(of: UIAlertController.self, in: controller))
            #expect(alert.title == "Unable to Save")
        }
    }

    @Test func moreActionsRemainAvailableBesideSaveAndDisableDuringSave() async throws {
        let state = EditorState()
        state.canSave = true
        state.showsActions = true
        try await withEditor(state) { _, navigation in
            #expect(saveButton(in: navigation)?.isEnabled == true)
            #expect(moreButton(in: navigation)?.isEnabled == true)

            try activate(#require(saveButton(in: navigation)))
            try await settle()
            #expect(moreButton(in: navigation)?.isEnabled == false)

            state.finishSave()
            try await settle()
            #expect(!state.isPresented)
        }
    }

    @Test(arguments: [false, true])
    func cancelOnlyDismissesUnmodifiedDrafts(isDirty: Bool) async throws {
        let state = EditorState()
        state.isDirty = isDirty
        try await withEditor(state) { controller, navigation in
            try activate(#require(cancelButton(in: navigation)))
            try await settle()
            #expect(state.isPresented == isDirty)
            #expect(state.saveCount == 0)
            if isDirty {
                let alert = try #require(descendant(of: UIAlertController.self, in: controller))
                #expect(alert.actions.contains { $0.style == .destructive })
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
