import CSSH2

nonisolated enum SFTPRenameOperation {
    /// SFTP v3 ignores RENAME flags. OpenSSH requires its POSIX extension to replace an existing file.
    /// Never unlink the original as a fallback: a failed commit must preserve it.
    static func perform(
        overwrite: Bool,
        posixRename: () -> Int32,
        standardRename: () -> Int32,
        lastStatus: () -> UInt
    ) -> Int32 {
        guard overwrite else { return standardRename() }
        let result = posixRename()
        if result == Int32(LIBSSH2_FX_OP_UNSUPPORTED)
            || (result == LIBSSH2_ERROR_SFTP_PROTOCOL && lastStatus() == UInt(LIBSSH2_FX_OP_UNSUPPORTED))
        {
            return standardRename()
        }
        return result
    }
}
