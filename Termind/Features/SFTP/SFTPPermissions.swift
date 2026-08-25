import Foundation

/// Editable Unix permission bits for the SFTP permissions sheet.
///
/// The remote attributes also contain a file-type mask. SETSTAT only needs the
/// four chmod digits, so the draft deliberately keeps those bits separate.
nonisolated struct SFTPPermissionDraft: Equatable, Sendable {
    static let editableMask: UInt32 = 0o7777

    let originalMode: UInt32
    private(set) var mode: UInt32
    private(set) var text: String

    init(permissions: UInt32) {
        let mode = permissions & Self.editableMask
        originalMode = mode
        self.mode = mode
        text = Self.octalString(for: mode)
    }

    var parsedMode: UInt32? {
        guard !text.isEmpty else { return nil }
        return UInt32(text, radix: 8).map { $0 & Self.editableMask }
    }

    var canSave: Bool {
        guard let parsedMode else { return false }
        return parsedMode != originalMode
    }

    func contains(_ permission: UInt32) -> Bool {
        mode & permission != 0
    }

    /// Accepts a transient editor value without destroying the last valid mode.
    /// This lets the field be cleared while the user types a replacement.
    @discardableResult
    mutating func accept(_ candidate: String) -> Bool {
        guard candidate.count <= 4,
            candidate.allSatisfy({ ("0"..."7").contains($0) })
        else { return false }
        text = candidate
        if let parsedMode { mode = parsedMode }
        return true
    }

    mutating func normalizeText() {
        guard let parsedMode else { return }
        mode = parsedMode
        text = Self.octalString(for: parsedMode)
    }

    mutating func set(_ permission: UInt32, enabled: Bool) {
        if enabled {
            mode |= permission
        } else {
            mode &= ~permission
        }
        mode &= Self.editableMask
        text = Self.octalString(for: mode)
    }

    static func octalString(for permissions: UInt32) -> String {
        String(format: "%04o", permissions & editableMask)
    }
}
