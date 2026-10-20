// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CSSH2
import Testing

@testable import TermindRemoteInfrastructure

@Suite struct SFTPRenameTests {
    @Test(arguments: [(true, Int32(0), "posix"), (false, LIBSSH2_ERROR_SFTP_PROTOCOL, "standard")])
    func overwritePolicySelectsTheRenameOperation(
        overwrite: Bool, expectedResult: Int32, expectedOperation: String
    ) {
        var calls: [String] = []
        let result = SFTPRenameOperation.perform(
            overwrite: overwrite,
            posixRename: {
                calls.append("posix")
                return 0
            },
            standardRename: {
                calls.append("standard")
                return LIBSSH2_ERROR_SFTP_PROTOCOL
            },
            lastStatus: { UInt(LIBSSH2_FX_FAILURE) })
        #expect(result == expectedResult)
        #expect(calls == [expectedOperation])
    }

    @Test(arguments: [Int32(LIBSSH2_FX_OP_UNSUPPORTED), LIBSSH2_ERROR_SFTP_PROTOCOL])
    func unsupportedExtensionFallsBackToStandardRename(_ result: Int32) {
        var calls: [String] = []
        #expect(
            SFTPRenameOperation.perform(
                overwrite: true,
                posixRename: {
                    calls.append("posix")
                    return result
                },
                standardRename: {
                    calls.append("standard")
                    return 0
                },
                lastStatus: { UInt(LIBSSH2_FX_OP_UNSUPPORTED) }) == 0)
        #expect(calls == ["posix", "standard"])
    }

    @Test(arguments: [LIBSSH2_ERROR_SFTP_PROTOCOL, LIBSSH2_ERROR_SOCKET_RECV, LIBSSH2_ERROR_EAGAIN])
    func realFailuresDoNotFallBackOrRemoveTheOriginal(_ failure: Int32) {
        var usedFallback = false
        let result = SFTPRenameOperation.perform(
            overwrite: true, posixRename: { failure },
            standardRename: {
                usedFallback = true
                return 0
            },
            lastStatus: { UInt(LIBSSH2_FX_FAILURE) })
        #expect(result == failure)
        #expect(!usedFallback)
    }
}
