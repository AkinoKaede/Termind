import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure

/// Tests run inside the signed app host. Once that host has an iCloud
/// entitlement SwiftData's `.automatic` default would incorrectly attempt to
/// mirror every test store through CloudKit. Production also opts out because
/// Vault sync is owned explicitly by `VaultSyncCoordinator`.
func localModelConfiguration(
    _ name: String? = nil,
    schema: Schema? = nil,
    isStoredInMemoryOnly: Bool = false,
    allowsSave: Bool = true,
    groupContainer: ModelConfiguration.GroupContainer = .automatic
) -> ModelConfiguration {
    ModelConfiguration(
        name, schema: schema, isStoredInMemoryOnly: isStoredInMemoryOnly,
        allowsSave: allowsSave, groupContainer: groupContainer,
        cloudKitDatabase: .none
    )
}

func localModelConfiguration(
    _ name: String? = nil,
    schema: Schema? = nil,
    url: URL,
    allowsSave: Bool = true
) -> ModelConfiguration {
    ModelConfiguration(
        name, schema: schema, url: url, allowsSave: allowsSave,
        cloudKitDatabase: .none
    )
}
