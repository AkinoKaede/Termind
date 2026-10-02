import Foundation

/// Shell commands generated from remote session context rather than typed by the user.
public nonisolated enum RemoteShellCommand {
    /// Encodes one literal shell argument without changing its contents.
    /// Backslashes keep paths readable; newlines need quotes because a
    /// backslash followed by a newline would remove both characters.
    public static func escapeArgument(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        if value.unicodeScalars.contains(where: { $0.value == 0x0A || $0.value == 0x0D }) {
            return "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
        }
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2F, 0x2E, 0x5F, 0x2D:
                break  // ASCII letters, digits, / . _ -
            case 0x80...0x10FFFF:
                break  // Shell syntax is ASCII; preserve Unicode paths verbatim.
            default:
                escaped.append("\\")
            }
            escaped.unicodeScalars.append(scalar)
        }
        return escaped
    }

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
