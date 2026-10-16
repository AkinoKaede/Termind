import SwiftUI
import TermindApplication

public struct HostMACAddressCandidatesView: View {
    private let candidates: [HostMACAddressCandidate]
    private let select: (HostMACAddressCandidate) -> Void
    public init(candidates: [HostMACAddressCandidate], select: @escaping (HostMACAddressCandidate) -> Void) {
        self.candidates = candidates
        self.select = select
    }

    public var body: some View {
        if candidates.isEmpty {
            ContentUnavailableView {
                Label(AppStrings.LocalNetwork.macAddress.swiftUIKey, systemImage: "network")
            } description: {
                Text(AppStrings.LocalNetwork.noMAC)
            }
        } else {
            List {
                Text(AppStrings.LocalNetwork.selectAdapter).foregroundStyle(.secondary)
                ForEach(candidates) { candidate in
                    Button {
                        select(candidate)
                    } label: {
                        LabeledContent(candidate.interface) {
                            Text(candidate.address.rawValue).monospaced()
                        }
                    }
                }
            }
        }
    }
}
