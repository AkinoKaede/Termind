import Foundation

/// Shell commands generated from remote session context rather than typed by the user.
public nonisolated enum RemoteShellCommand {
    /// Builds a one-shot directory change for a newly opened shell.
    ///
    /// Single-quoting keeps spaces and shell punctuation inert; embedded
    /// apostrophes are closed, emitted literally, and reopened.
    public static func changeDirectory(to path: String) -> String? {
        guard !path.isEmpty else { return nil }
        let quoted = path.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "cd '\(quoted)'"
    }
}
