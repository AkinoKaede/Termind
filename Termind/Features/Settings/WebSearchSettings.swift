import SwiftUI

struct WebSearchSettings: View {
    @AppStorage(SettingsKey.webSearchEnabled) private var isEnabled =
        SettingsKey.defaultWebSearchEnabled
    @AppStorage(SettingsKey.webSearchBuiltIn) private var usesBuiltIn =
        SettingsKey.defaultWebSearchBuiltIn

    @State private var probe: ProbeState = .idle

    private enum ProbeState: Equatable {
        case idle
        case running
        case succeeded(Int)
        case failed(String)
    }

    var body: some View {
        Section {
            Toggle("Enable Web Search", isOn: $isEnabled)

            Toggle("Prefer Built-in Web Search", isOn: $usesBuiltIn)
                .disabled(!isEnabled)

            Text(
                usesBuiltIn
                    ? String(
                        localized:
                            "Models with provider-native search use it directly. Other models search Google, Bing, DuckDuckGo, and Yahoo from this Mac and read result pages as Markdown."
                    )
                    : String(
                        localized:
                            "Every model searches Google, Bing, DuckDuckGo, and Yahoo from this Mac and reads result pages as Markdown."
                    )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Web Search")
        }

        Section {
            Button("Test Search") { runProbe() }
                .disabled(probe == .running || !isEnabled)

            switch probe {
            case .idle:
                EmptyView()
            case .running:
                Label("Searching…", systemImage: "ellipsis.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .succeeded(let count):
                Label(
                    count == 0
                        ? String(localized: "The search completed, but no readable pages were found.")
                        : String(localized: "Readable pages:") + " \(count)",
                    systemImage: count == 0 ? "exclamationmark.triangle" : "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(count == 0 ? .orange : .green)
            case .failed(let reason):
                Label(reason, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!isEnabled)
    }

    private func runProbe() {
        probe = .running
        Task {
            do {
                let results = try await ScrubberWebClient().search(
                    "Termind web search test", count: 3
                )
                probe = .succeeded(results.count)
            } catch {
                probe = .failed(error.localizedDescription)
            }
        }
    }
}
