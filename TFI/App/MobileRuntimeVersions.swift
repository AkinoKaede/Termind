import GhosttyKit
import TermindRemoteInfrastructure

nonisolated enum MobileRuntimeVersions {
    static let unknown = "Unknown"

    static var ghostty: String {
        let info = ghostty_info()
        return decode(info.version, length: Int(info.version_len)) ?? unknown
    }

    static var libssh2: String { SSHRuntimeVersions.libssh2 }
    static var openSSL: String { SSHRuntimeVersions.openSSL }

    static func decode(_ pointer: UnsafePointer<CChar>?, length: Int) -> String? {
        guard let pointer, length >= 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: pointer, count: length),
            as: UTF8.self
        )
    }
}
