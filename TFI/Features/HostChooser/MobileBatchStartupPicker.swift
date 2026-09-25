import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileBatchStartupPicker: View {
    let library: HostLibraryModel
    let connect: ([Host.ID], MobileConnectionProtocol) -> Void
    @State private var connectionProtocol = MobileConnectionProtocol.ssh

    var body: some View {
        MobileMultiHostPicker(
            library: library, useCase: connectionProtocol.useCase, selected: [],
            title: AppStrings.Vault.batchStartup, actionTitle: AppStrings.Common.connect,
            emptyDescription: AppStrings.Vault.addAHostToConnectToIt, requiresSelection: true,
            save: { connect($0, connectionProtocol) },
            header: { MobileConnectionProtocolPicker(selection: $connectionProtocol) })
    }
}
