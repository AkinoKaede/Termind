import AppKit
import TermindPresentation

/// Keep the native field editor and binding in sync without interrupting marked-text composition.
enum SingleLineFieldEditing {
    static func paste() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
            let field = editor.delegate as? NSTextField, !(field is NSSecureTextField),
            let text = NSPasteboard.general.string(forType: .string)
        else { return }
        insert(text, into: editor)
    }

    static func insert(_ text: String, into editor: NSTextView) {
        editor.insertText(SingleLineTextInput.normalized(text), replacementRange: editor.selectedRange())
    }

    static func normalizedValue(in field: NSTextField) -> String? {
        let editor = field.currentEditor() as? NSTextView
        guard editor?.hasMarkedText() != true else { return nil }
        let original = field.stringValue
        let normalized = SingleLineTextInput.normalized(original)
        guard original != normalized else { return original }
        let selection = editor?.selectedRange()
        field.stringValue = normalized
        if let editor, let selection {
            let originalString = original as NSString
            let start = min(selection.location, originalString.length)
            let end = start + min(selection.length, originalString.length - start)
            let normalizedStart = (SingleLineTextInput.normalized(originalString.substring(to: start)) as NSString)
                .length
            let normalizedEnd = (SingleLineTextInput.normalized(originalString.substring(to: end)) as NSString).length
            editor.string = normalized
            editor.setSelectedRange(NSRange(location: normalizedStart, length: normalizedEnd - normalizedStart))
        }
        return normalized
    }
}
