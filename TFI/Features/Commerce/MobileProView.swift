import SwiftUI
import TermindInfrastructure

struct MobileProView: View {
    @Bindable var pro: ProAccessController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    accessStatus
                    featureList
                    secondaryActions
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { purchaseActions }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
                }
            }
        }
        .mobileSheetPresentation()
        .task { await pro.reloadProducts() }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("Termind Pro").font(.largeTitle.bold())
            Text("One purchase for AI, more monitored servers, remote MCP tools, and iCloud sync.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var accessStatus: some View {
        switch pro.status {
        case .loading:
            statusCard("Checking…", symbol: "arrow.triangle.2.circlepath", tint: .secondary)
        case .free:
            statusCard("Free", symbol: "person.crop.circle", tint: .secondary)
        case .trialActive(let expiresAt):
            statusCard(
                "14-Day Trial", symbol: "clock.fill", tint: .orange,
                detail: Text(expiresAt, format: .dateTime.year().month().day().hour().minute()))
        case .trialExpired:
            statusCard("Trial Ended", symbol: "clock.badge.xmark", tint: .orange)
        case .purchased(.purchased):
            statusCard("Purchased", symbol: "checkmark.seal.fill", tint: .green)
        case .purchased(.familyShared):
            statusCard("Family Shared", symbol: "person.3.fill", tint: .green)
        case .verificationFailed:
            statusCard(
                "The App Store could not verify this purchase.",
                symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .unrestrictedForTesting:
            statusCard("Pro Active", symbol: "checkmark.seal.fill", tint: .green)
        }
    }

    private var featureList: some View {
        VStack(spacing: 0) {
            feature("Use the AI Assistant", symbol: "sparkles")
            Divider().padding(.leading, 52)
            feature("Monitor more than 3 servers", symbol: "waveform.path.ecg")
            Divider().padding(.leading, 52)
            feature("Upload files by dropping them on a terminal", symbol: "arrow.up.doc")
            Divider().padding(.leading, 52)
            feature("Connect remote MCP tools", symbol: "server.rack")
            Divider().padding(.leading, 52)
            feature("Sync Vault, Metrics, and Settings across devices", symbol: "icloud")
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary, lineWidth: 1)
        }
    }

    @ViewBuilder private var purchaseActions: some View {
        if showsPurchaseActions {
            VStack(spacing: 10) {
                if pro.isProcessing {
                    ProgressView("Contacting the App Store…")
                }
                if let message = pro.message {
                    Text(message).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if pro.canStartTrial {
                    Button {
                        Task { await pro.startTrial() }
                    } label: {
                        Text("Start 14-Day Free Trial").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button {
                        Task { await pro.purchase() }
                    } label: {
                        Text(purchaseTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                    .disabled(!pro.canPurchase)
                } else if showsPurchase {
                    Button {
                        Task { await pro.purchase() }
                    } label: {
                        Text(purchaseTitle).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!pro.canPurchase)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
    }

    private var secondaryActions: some View {
        VStack(spacing: 10) {
            Button("Restore Purchase") { Task { await pro.restorePurchases() } }
                .buttonStyle(.plain).foregroundStyle(.tint).disabled(pro.isProcessing)
            Text("Permanent unlock · Supports Apple Family Sharing · AI provider charges are separate")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
    }

    private var showsPurchaseActions: Bool {
        pro.isProcessing || pro.message != nil || pro.canStartTrial || showsPurchase
    }

    private var showsPurchase: Bool {
        guard pro.canPurchase else { return false }
        if case .loading = pro.status { return false }
        return true
    }

    private var purchaseTitle: String {
        guard let price = pro.displayPrice else { return String(localized: "Buy Termind Pro") }
        return String(localized: "Buy Termind Pro — \(price)")
    }

    private func statusCard(
        _ title: LocalizedStringKey,
        symbol: String,
        tint: Color,
        detail: Text? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(tint)
                .frame(width: 32, height: 32).background(tint.opacity(0.14), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let detail { detail.font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(tint.opacity(0.22), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }

    private func feature(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(.tint)
                .frame(width: 32, height: 32).background(.tint.opacity(0.12), in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
