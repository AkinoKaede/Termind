import Foundation
import TermindDomain

@Observable
public final class TerminalCustomThemeDraft: Identifiable {
    public var value: TerminalCustomTheme
    public private(set) var original: TerminalCustomTheme
    public private(set) var isNew: Bool
    public var id: UUID { value.id }
    public var isDirty: Bool { value != original }

    public init(_ value: TerminalCustomTheme, isNew: Bool) {
        self.value = value
        original = value
        self.isNew = isNew
    }

    public func refresh(from model: TerminalSettingsModel) {
        guard !isNew, !isDirty, let remote = model.themeLibrary.themes.first(where: { $0.id == id }) else { return }
        original = remote
        value = remote
    }

    public func isDeleted(in model: TerminalSettingsModel) -> Bool {
        !isNew && !model.themeLibrary.themes.contains { $0.id == id }
    }

    public func save(in model: TerminalSettingsModel) -> Bool {
        var saved = value
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.saveCustomTheme(saved, isNew: isNew) else { return false }
        value = saved
        original = saved
        isNew = false
        return true
    }

    public func makeCopy(name: String) {
        value.id = UUID()
        value.name = name
        isNew = true
    }
}
