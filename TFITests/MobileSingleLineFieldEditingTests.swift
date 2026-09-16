import SwiftUI
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite("Mobile single-line field editing", .serialized)
@MainActor
struct MobileSingleLineFieldEditingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func hostFormNormalizesPasteAndPreservesFocus(language: String) async throws {
        let draft = MobileSingleLineHostTestDraft()
        let controller = UIHostingController(
            rootView: MobileSingleLineHostTestForm(draft: draft)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.singleLineInputAdapter, { AnyView(MobileSingleLineFieldInput()) }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 520, height: 600))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let field = try #require(findField(in: controller.view, value: "fixture.invalid"))
        let inputDelegate = field.delegate
        let pasteDelegate = try #require(field.pasteDelegate as? MobileSingleLineFieldInput.DelegateProxy)
        #expect(field.becomeFirstResponder())
        let selection = try #require(field.textRange(from: field.beginningOfDocument, to: field.endOfDocument))
        field.selectedTextRange = selection
        // Invoke the native paste transformation synchronously: other UI suites can
        // change the key window while UIKit asynchronously loads item providers.
        let pasted = pasteDelegate.textPasteConfigurationSupporting(
            field, combineItemAttributedStrings: [NSAttributedString(string: "first.example\r\n\nsecond.example")],
            for: selection)
        field.insertText(pasted.string)
        #expect(draft.host.host == "first.example second.example")
        #expect(field.text == "first.example second.example")
        #expect(field.isFirstResponder)
        #expect(field.delegate === inputDelegate)
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
        let chineseSelection = try #require(field.selectedTextRange)
        let chinesePaste = pasteDelegate.textPasteConfigurationSupporting(
            field, combineItemAttributedStrings: [NSAttributedString(string: "中文\u{2028}名称")], for: chineseSelection)
        field.insertText(chinesePaste.string)
        #expect(draft.host.host == "中文 名称")
        #expect(field.isFirstResponder)
    }

    private func findField(in view: UIView, value: String) -> UITextField? {
        if let field = view as? UITextField, field.text == value { return field }
        return view.subviews.lazy.compactMap { findField(in: $0, value: value) }.first
    }
}

@Observable
@MainActor
private final class MobileSingleLineHostTestDraft {
    var host = TermindDomain.Host(name: "Fixture", host: "fixture.invalid")
}

private struct MobileSingleLineHostTestForm: View {
    @Bindable var draft: MobileSingleLineHostTestDraft

    var body: some View { Form { HostConnectionFields(host: $draft.host) } }
}
