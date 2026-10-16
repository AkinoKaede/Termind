import TermindApplication
import TermindDomain

extension RemoteSessionBackendRegistry {
    public nonisolated static var live: Self {
        Self(
            Dictionary(
                uniqueKeysWithValues: SessionPersistenceBackendID.supported.map {
                    id -> (SessionPersistenceBackendID, Factory) in
                    (id, { execute in RemoteMultiplexerService(backend: id, execute: execute) })
                }))
    }
}
