import SwiftUI

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

    private var modelProviders: [ModelProvider] { app.ai.modelProviders }

    var body: some View {
        Section("Model Providers") {
            ForEach(modelProviders) { provider in
                ModelProviderRow(provider: provider) { edit(provider.id, false) }
            }

            FormNavigationAction(title: "Add Provider") {
                // Created immediately rather than assembled inside the sheet, so
                // there is one code path for "new" and "edit" and no half-built
                // provider living in a view's `@State`. Cancelling takes it back
                // out again — which is what `isNew` below is for.
                let provider = ModelProvider(name: String(localized: "New Provider"))
                app.ai.upsert(provider)
                edit(provider.id, true)
            }

            Text(
                "Requests go directly from this Mac to each endpoint, not through an SSH host."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let error = app.ai.storageError {
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
            Image(systemName: provider.kind.symbol)
                .foregroundStyle(provider.isEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .frame(width: Metrics.Sidebar.rowIcon)

            VStack(alignment: .leading, spacing: 1) {
                Text(provider.name)
                    .lineLimit(1)
                Text(provider.resolvedBaseURL)
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
                .accessibilityLabel(Text("Enable \(provider.name)"))

            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edit \(provider.name)"))
        }
        .contentShape(.rect)
        // The whole row opens the editor; the toggle and the chevron are
        // ordinary controls layered on top and keep their own hit areas.
        .onTapGesture(perform: edit)
        .help(Text(provider.resolvedRequestURL()))
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { provider.isEnabled },
            set: { app.ai.setModelProviderEnabled($0, for: provider.id) }
        )
    }

    /// The two facts that decide whether this row can do anything: does it have
    /// a credential, and does it know any models.
    ///
    /// "No Key" is orange rather than red — an unfinished provider is a normal
    /// state on the way to a finished one, not an error.
    @ViewBuilder
    private var chips: some View {
        CardChip(text: provider.kind.displayName)

        if !provider.hasCredential {
            CardChip(text: String(localized: "No Key"), symbol: "exclamationmark.circle", tint: .orange)
        } else if provider.models.isEmpty {
            CardChip(text: String(localized: "No Models"), symbol: "questionmark.circle")
        } else {
            CardChip(text: "\(provider.models.count)", symbol: "cube")
        }
    }
}
