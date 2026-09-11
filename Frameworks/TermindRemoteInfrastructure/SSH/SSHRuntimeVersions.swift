import CSSH2
import OpenSSL

public nonisolated enum SSHRuntimeVersions {
    public static var libssh2: String {
        guard let version = libssh2_version(0) else { return "Unknown" }
        return String(cString: version)
    }
    public static var openSSL: String {
        "\(OPENSSL_version_major()).\(OPENSSL_version_minor()).\(OPENSSL_version_patch())"
    }
}
