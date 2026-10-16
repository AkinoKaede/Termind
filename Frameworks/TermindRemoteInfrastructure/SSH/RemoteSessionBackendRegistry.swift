import TermindApplication
import TermindDomain

extension RemoteSessionBackendRegistry {
    public nonisolated static var live: Self {
        Self(
            Dictionary(
                uniqueKeysWithValues: RemoteMultiplexerRegistry.dialects.map {
                    dialect -> (SessionPersistenceBackendID, Factory) in
                    let id = dialect.id
                    return (id, { execute in RemoteMultiplexerService(backend: id, execute: execute) })
                }))
    }
}
