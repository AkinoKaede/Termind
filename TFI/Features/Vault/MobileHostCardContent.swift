import SwiftUI
import TermindDomain
import TermindPresentation

struct MobileHostCardContent: View {
    let host: TermindDomain.Host
    let address: String
    let status: ConnectionStatus?
    let lastConnectedAt: Date?

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                HostConnectionIcon(
                    host: host, status: status,
                    badgeStyle: .card(background: Color(uiColor: .systemBackground), pulses: false)
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(address).font(.caption.monospaced())
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(AppStrings.Vault.openWorkspace.swiftUIKey)
    }

    private var footer: some View {
        ZStack {
            // Reserve the chip's actual line height and padding, including Dynamic Type.
            MobileCardChip(text: " ")
                .hidden()
                .accessibilityHidden(true)

            HStack(spacing: 6) {
                ForEach(MobileCardLayout.visibleTags(host.tags), id: \.self) { tag in
                    MobileCardChip(text: tag)
                }
                Spacer(minLength: 6)
                Text(
                    lastConnectedAt
                        .map { $0.formatted(.relative(presentation: .numeric).locale(locale)) }
                        ?? String(localized: AppStrings.Vault.never)
                )
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}
