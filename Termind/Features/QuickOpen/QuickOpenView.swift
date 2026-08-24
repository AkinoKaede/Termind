import SwiftUI

struct QuickOpenView: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var selectedID: AppCommandDescriptor.ID?
    @FocusState private var searchFocused: Bool

    private var matches: [AppCommandDescriptor] {
        app.commands.commands(app: app, window: window).filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Metrics.Space.m) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Open a page, workspace, host, or command", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($searchFocused)
                    .onSubmit(performSelection)
            }
            .padding(Metrics.Space.l)

            Divider()

            if matches.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(matches, selection: $selectedID) { command in
                    Button {
                        perform(command)
                    } label: {
                        HStack(spacing: Metrics.Space.m) {
                            Image(systemName: command.symbol)
                                .frame(width: 22)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(command.title).lineLimit(1)
                                if let subtitle = command.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .tag(command.id)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 620, height: 430)
        .onAppear {
            searchFocused = true
            selectedID = matches.first?.id
        }
        .onChange(of: query) {
            selectedID = matches.first?.id
        }
    }

    private func performSelection() {
        let command =
            selectedID.flatMap { id in matches.first { $0.id == id } }
            ?? matches.first
        if let command { perform(command) }
    }

    private func perform(_ command: AppCommandDescriptor) {
        app.commands.perform(
            command.target, app: app, window: window,
            openSettings: { openSettings() }
        )
        dismiss()
    }
}
