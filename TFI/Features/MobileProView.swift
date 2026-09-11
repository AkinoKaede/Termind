import SwiftUI
import TermindInfrastructure
import TermindRemoteInfrastructure

struct MobileProView: View {
    @Bindable var pro: ProAccessController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Termind Pro") {
                    Label("Assistant", systemImage: "sparkles")
                    Label("iCloud Sync", systemImage: "icloud")
                    Label("Unlimited Metrics", systemImage: "gauge.with.dots.needle.33percent")
                    Label("Remote MCP", systemImage: "network")
                }
                Section {
                    if pro.hasProAccess {
                        Label("Pro Active", systemImage: "checkmark.seal.fill")
                    } else {
                        Button {
                            Task { await pro.purchase() }
                        } label: {
                            LabeledContent("Upgrade to Pro", value: pro.displayPrice ?? "")
                        }
                        .disabled(!pro.canPurchase)
                        if pro.canStartTrial { Button("Start Free Trial") { Task { await pro.startTrial() } } }
                    }
                    Button("Restore Purchases") { Task { await pro.restorePurchases() } }.disabled(pro.isProcessing)
                    if pro.isProcessing { ProgressView() }
                    if let message = pro.message { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Termind Pro")
            .toolbar { Button("Done") { dismiss() } }
        }.presentationDetents([.large])
    }
}
