import Foundation
import TermindApplication
import TermindRemoteInfrastructure

extension SFTPTransferCoordinator {
    convenience init(
        store: HostLibraryModel,
        globalLimit: Int? = nil,
        perHostLimit: Int? = nil
    ) {
        self.init(
            store: store,
            clientFactory: { SFTPClient() },
            globalLimit: globalLimit,
            perHostLimit: perHostLimit
        )
    }
}
