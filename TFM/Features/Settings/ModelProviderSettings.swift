import AgentKit
import SwiftUI
import TermindDomain
import TermindPresentation

/// The "Model Providers" section of the Settings page.
///
/// A row per endpoint, plus the one line of small print that matters most here:
/// requests go from this Mac to the address in that row, and nowhere else. That
/// sentence is the product, not a disclaimer — an SSH client that shipped
/// terminal output through somebody else's server would be a different and much
/// worse thing.
struct ModelProviderSettings: View {
    @Environment(AppModel.self) private var app
    let edit: (ModelProvider.ID, Bool) -> Void

    private var modelProviders: [ModelProvider] { app.aiConfiguration.modelProviders }

    var body: some View {
        Section(TermindCopy.Settings.modelProviders.swiftUIKey) {
            ForEach(modelProviders) { provider in
                ModelProviderRow(provider: provider) { edit(provider.id, false) }
            }

            FormNavigationAction(title: TermindCopy.Settings.addProvider) {
                // Created immediately rather than assembled inside the sheet, so
                // there is one code path for "new" and "edit" and no half-built
                // provider living in a view's `@State`. Cancelling takes it back
                // out again — which is what `isNew` below is for.
                let provider = ModelProvider(name: "")
                if app.aiConfiguration.saveProvider(provider, endpoint: ProviderEndpoint()) {
                    edit(provider.id, true)
                }
            }

            Text(
                TermindCopy.Settings.directProviderConnectionExplanation
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let error = app.aiConfiguration.storageError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One provider, as a row.
///
/// Reads left to right the way the question is asked: what is it called, what
/// kind is it, is it usable. The toggle sits in the row rather than in the
/// editor because turning a provider off is a thing you do *while looking at the
/// list* — usually to stop a second one's models cluttering a picker.
private struct ModelProviderRow: View {
    let provider: ModelProvider
    let edit: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            Image(systemName: provider.apiFormat.symbol)
                .foregroundStyle(provider.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: Metrics.Sidebar.rowIcon)

            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                    .lineLimit(1)
                Group {
                    if provider.usesVertexEndpoint {
                        Text(
                            ModelProviderForm.hasValidAddress(provider)
                                ? provider.requestURL() : String(localized: TermindCopy.Settings.vertexAi))
                    } else if endpoint.isConfigured {
                        Text(endpoint.url)
                    } else {
                        Text(TermindCopy.Settings.needsAUrl)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }

            Spacer(minLength: Metrics.Space.m)

            chips

            Toggle("", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(Text(TermindCopy.Settings.enableNamed(provider.name)))

            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(TermindCopy.Settings.edit(provider.name)))
        }
        .contentShape(.rect)
        // The whole row opens the editor; the toggle and the chevron are
        // ordinary controls layered on top and keep their own hit areas.
        .onTapGesture(perform: edit)
        .help(Text(endpoint.isConfigured ? provider.requestURL() : ""))
    }

    private var endpoint: ProviderEndpoint {
        app.aiConfiguration.endpoint(for: provider.id)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { provider.isEnabled },
            set: { app.aiConfiguration.setModelProviderEnabled($0, for: provider.id) }
        )
    }

    /// Credentials are optional, so model availability determines the status.
    @ViewBuilder
    private var chips: some View {
        CardChip(text: provider.apiFormat.displayName)

        if provider.models.isEmpty {
            CardChip(text: String(localized: TermindCopy.Settings.noModels), symbol: "questionmark.circle")
        } else {
            CardChip(text: "\(provider.models.count)", symbol: "cube")
        }
    }
}
