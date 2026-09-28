import CSSH2
import Darwin
import Foundation
import Logging
import TermindApplication
import TermindDomain

nonisolated final class SecurityKeySigner {
    let credential: SecurityKeyCredential
    let keyName: String
    let exchange: SSHKeyboardInteractiveExchange
    var error: (any Error)?
    var stage = "public_key_offer"
    let logger: Logger

    init(credential: SecurityKeyCredential, keyName: String, exchange: SSHKeyboardInteractiveExchange, logger: Logger) {
        self.logger = logger
        self.credential = credential
        self.keyName = keyName
        self.exchange = exchange
    }
}

nonisolated func securityKeySignCallback(
    _ session: OpaquePointer?, _ signature: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
    _ length: UnsafeMutablePointer<Int>?, _ data: UnsafePointer<UInt8>?, _ dataLength: Int,
    _ abstract: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Int32 {
    guard let opaque = abstract?.pointee, let session, let signature, let length, let data else {
        return LIBSSH2_ERROR_INVAL
    }
    let signer = Unmanaged<SecurityKeySigner>.fromOpaque(opaque).takeUnretainedValue()
    let started = ContinuousClock.now
    defer {
        let elapsed = started.duration(to: .now).components
        let timeout = libssh2_session_get_timeout(session)
        if timeout > 0 {
            libssh2_session_set_timeout(
                session,
                timeout + Int(elapsed.seconds) * 1000
                    + Int(elapsed.attoseconds / 1_000_000_000_000_000))
        }
    }
    do {
        signer.stage = "signing"
        signer.logger.info("ssh.security_key.signing", metadata: ["stage": "signing"])
        let blob = try signer.exchange.sign(
            credential: signer.credential, keyName: signer.keyName, data: Data(bytes: data, count: dataLength))
        signer.stage = "server_verification"
        signer.logger.info("ssh.security_key.signed", metadata: ["stage": "server_verification"])
        // These sessions use libssh2's default malloc/free allocator, like the existing enclave signer.
        guard let buffer = malloc(blob.count) else { return LIBSSH2_ERROR_ALLOC }
        blob.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        signature.pointee = buffer.assumingMemoryBound(to: UInt8.self)
        length.pointee = blob.count
        return 0
    } catch {
        signer.error = error
        return LIBSSH2_ERROR_PUBLICKEY_UNVERIFIED
    }
}
