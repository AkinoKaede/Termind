import Foundation
import SwiftUI
import TermindPresentation
import Testing

@Suite("Single-line text editing")
struct SingleLineTextInputTests {
    @Test func attributedPasteKeepsSurroundingAttributesAndUnicodeOffsets() {
        let key = NSAttributedString.Key("testStyle")
        let original = NSMutableAttributedString(string: "👩🏽‍💻中文\r\n\nName", attributes: [key: "first"])
        original.addAttribute(key, value: "second", range: NSRange(location: original.length - 4, length: 4))
        let normalized = SingleLineTextInput.normalized(original)
        #expect(normalized.string == "👩🏽‍💻中文 Name")
        #expect(normalized.attribute(key, at: 0, effectiveRange: nil) as? String == "first")
        #expect(normalized.attribute(key, at: normalized.length - 1, effectiveRange: nil) as? String == "second")
        #expect(original.string == "👩🏽‍💻中文\r\n\nName")
    }

    @Test(arguments: ["\n", "\r", "\r\n", "\n\r\n", "\u{000B}", "\u{000C}", "\u{0085}", "\u{2028}", "\u{2029}"])
    func consecutiveLineBreaksBecomeOneSpace(_ lineBreak: String) {
        #expect(SingleLineTextInput.normalized("first\(lineBreak)second") == "first second")
        #expect(SingleLineTextInput.normalized("\(lineBreak)first\(lineBreak)") == " first ")
    }

    @Test(arguments: ["", "example.invalid", "中文主机", "  two  spaces \t remain  ", "👩🏽‍💻服务器"])
    func singleLineContentIsUnchanged(_ text: String) {
        #expect(SingleLineTextInput.normalized(text) == text)
    }

    @Test func separatedLineBreakRunsKeepExistingSpacesAndTabs() {
        #expect(SingleLineTextInput.normalized("a\r\n\n b\t\nc") == "a  b\t c")
    }

    @MainActor
    @Test func bindingReadsLegacyValuesUnchangedAndNormalizesOnlyWrites() {
        var stored = "legacy\nvalue"
        var receivedTransaction: Transaction?
        let source = Binding<String>(
            get: { stored },
            set: { value, transaction in
                stored = value
                receivedTransaction = transaction
            }
        )
        let field = source.singleLineText
        #expect(field.wrappedValue == "legacy\nvalue")
        #expect(stored == "legacy\nvalue")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        field.transaction(transaction).wrappedValue = "新的\r\n\n名称"
        #expect(stored == "新的 名称")
        #expect(receivedTransaction?.disablesAnimations == true)
        source.wrappedValue = "script\nbody"
        #expect(stored == "script\nbody")
    }
}
