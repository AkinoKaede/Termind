import CSSH2
import GhosttyKit
import OpenSSL

nonisolated enum RuntimeVersions {
    static let unknown = "Unknown"

    static var ghostty: String {
        let info = ghostty_info()
        return decode(info.version, length: Int(info.version_len)) ?? unknown
    }

    static var libssh2: String {
        guard let version = libssh2_version(0) else { return unknown }
        return String(cString: version)
    }

    static var openSSL: String {
        "\(OPENSSL_version_major()).\(OPENSSL_version_minor()).\(OPENSSL_version_patch())"
    }

    static func decode(_ pointer: UnsafePointer<CChar>?, length: Int) -> String? {
        guard let pointer, length >= 0 else { return nil }
        return String(
            decoding: UnsafeRawBufferPointer(start: pointer, count: length),
            as: UTF8.self
        )
    }
}
