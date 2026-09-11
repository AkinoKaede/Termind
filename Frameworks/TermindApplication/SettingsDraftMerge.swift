import Foundation

/// Three-way merging for explicit-save editors. Unedited fields follow the latest replica.
public enum SettingsDraftMerge {
    public enum Conflict: LocalizedError {
        case changed
        public var errorDescription: String? {
            String(
                localized: "This configuration changed on another device. Reopen the editor to load the latest version."
            )
        }
    }

    public static func value<Value: Equatable>(_ original: Value, _ draft: Value, _ current: Value) throws -> Value {
        if draft == original { return current }
        guard current == original || current == draft else { throw Conflict.changed }
        return draft
    }

    public static func collection<Item: Identifiable & Equatable>(
        _ original: [Item], _ draft: [Item], _ current: [Item],
        merge: (Item, Item, Item) throws -> Item
    ) throws -> [Item] {
        var result: [Item] = []
        let ids = current.map(\.id) + draft.filter { item in !current.contains { $0.id == item.id } }.map(\.id)
        for id in ids {
            let old = original.first { $0.id == id }
            let local = draft.first { $0.id == id }
            let remote = current.first { $0.id == id }
            if let old, let local, let remote {
                result.append(try merge(old, local, remote))
            } else if let item = try value(old, local, remote) {
                result.append(item)
            }
        }
        return result
    }
}

public struct SettingsFields<Value> {
    private let original: Value
    private let draft: Value
    public private(set) var result: Value

    public init(_ original: Value, _ draft: Value, _ current: Value) {
        self.original = original
        self.draft = draft
        result = current
    }

    public mutating func merge<Field: Equatable>(_ path: WritableKeyPath<Value, Field>) throws {
        result[keyPath: path] = try SettingsDraftMerge.value(
            original[keyPath: path], draft[keyPath: path], result[keyPath: path])
    }
}
