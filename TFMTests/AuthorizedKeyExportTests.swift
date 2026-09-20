import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

struct AuthorizedKeyExportTests {
    @Test
    func exportPlacesTheKeyNameCommentAboveThePublicKey() throws {
        let input = try SSHConnectionOpener.authorizedKeyInstallInput(
            publicKey: "ssh-ed25519 AAAAC3Nza test@example.com",
            keyName: "Production"
        )

        #expect(
            String(decoding: input, as: UTF8.self)
                == "# Production Key by Termind\nssh-ed25519 AAAAC3Nza test@example.com\n"
        )
    }

    @Test
    func exportKeepsTheGeneratedCommentOnOneLine() throws {
        let input = try SSHConnectionOpener.authorizedKeyInstallInput(
            publicKey: "ssh-ed25519 AAAAC3Nza",
            keyName: "  Production\n\tServer  "
        )

        #expect(
            String(decoding: input, as: UTF8.self)
                == "# Production Server Key by Termind\nssh-ed25519 AAAAC3Nza\n"
        )
    }
}
