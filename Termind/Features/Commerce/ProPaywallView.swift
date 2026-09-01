import SwiftUI

struct ProPaywallView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var isReviewDemoExpanded = false
    @State private var isReviewDemoUnlocked = false
    @State private var reviewCode = ""
    @State private var reviewCodeIsInvalid = false

    private var pro: ProAccessController { app.proAccess }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: Metrics.Space.l) {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.tint)
                VStack(spacing: Metrics.Space.s) {
                    Text("Termind Pro")
                        .font(.largeTitle.bold())
                        .onTapGesture(count: 7) {
                            isReviewDemoUnlocked = true
                            isReviewDemoExpanded = true
                        }
                    Text("One purchase. Your advanced workspace, AI, MCP, and iCloud tools—forever.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 430)
                }
            }
            .padding(.top, 36)

            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                feature("Arrange multiple panes and broadcast input", "rectangle.split.2x1")
                feature("Use the AI Assistant", "sparkles")
                feature("Upload files by dropping them on a terminal", "arrow.up.doc")
                feature("Connect MCP tools and run the built-in MCP Server", "server.rack")
                feature("Sync your Vault through your private iCloud database", "icloud")
            }
            .padding(.vertical, 28)

            if let message = pro.message {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).padding(.bottom, 12)
            }

            VStack(spacing: Metrics.Space.s) {
                if trialIsAvailable {
                    Button("Start 7-Day Free Trial") { Task { await pro.startTrial() } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Text("No subscription. You will not be charged when the trial ends.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if trialIsAvailable {
                    Button(purchaseTitle) {
                        Task { await pro.purchase() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button(purchaseTitle) {
                        Task { await pro.purchase() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button("Restore Purchase") { Task { await pro.restorePurchases() } }
                    .buttonStyle(.link)
                if isReviewDemoUnlocked || pro.isReviewDemoModeEnabled {
                    DisclosureGroup("App Review Demo", isExpanded: $isReviewDemoExpanded) {
                        VStack(alignment: .leading, spacing: Metrics.Space.s) {
                            Text("For App Review only.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if pro.isReviewDemoModeEnabled {
                                Label("Trial Ended", systemImage: "clock.badge.xmark")
                                Button("Exit Demo Mode") {
                                    Task { await pro.deactivateReviewDemo() }
                                }
                            } else {
                                TextField("Review Code", text: $reviewCode)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(activateReviewDemo)
                                Button("Show Expired Trial", action: activateReviewDemo)
                                    .disabled(reviewCode.isEmpty)
                                if reviewCodeIsInvalid {
                                    Text("The review code is invalid.")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .padding(.top, Metrics.Space.s)
                    }
                    .frame(maxWidth: 360)
                }
                Text("Permanent unlock · Supports Apple Family Sharing · AI provider charges are separate")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 30)
        }
        .frame(width: 560)
        .padding(.horizontal, 40)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    private var trialIsAvailable: Bool {
        if case .free(trialAvailable: true) = pro.status { return true }
        return false
    }

    private var purchaseTitle: String {
        guard let price = pro.displayPrice else { return String(localized: "Buy Termind Pro") }
        return String(localized: "Buy Termind Pro — \(price)")
    }

    private func activateReviewDemo() {
        reviewCodeIsInvalid = !pro.activateReviewDemo(using: reviewCode)
        if !reviewCodeIsInvalid { reviewCode = "" }
    }

    private func feature(_ title: LocalizedStringKey, _ symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.body)
    }
}

struct ProPaywallPresenter: ViewModifier {
    let app: AppModel

    func body(content: Content) -> some View {
        @Bindable var pro = app.proAccess
        content.sheet(isPresented: $pro.isPaywallPresented) {
            ProPaywallView().environment(app)
        }
    }
}

extension View {
    func proPaywallPresenter(app: AppModel) -> some View {
        modifier(ProPaywallPresenter(app: app))
    }
}
