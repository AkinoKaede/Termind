import TermindApplication
import TermindDomain

extension RemoteSessionBackendRegistry {
    public nonisolated static var live: Self {
        Self(
            Dictionary(
                uniqueKeysWithValues: RemoteMultiplexerRegistry.dialects.map {
                    dialect -> (SessionPersistenceBackendID, Factory) in
                    (dialect.id, { execute in dialect.backend(execute: execute) })
                }))
    }
}
