import SwiftUI
import UIKit

struct MobileCommandHistoryView: View {
    let workspace: MobileWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var clearing = false

    var body: some View {
        NavigationStack {
            List {
                let _ = workspace.commandHistory.revision
                ForEach(workspace.commandHistory.entries(for: workspace.descriptor.hostID, matching: query)) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.command).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text(entry.executedAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if let code = entry.exitStatus { LabeledContent("Exit Status", value: code.formatted()) }
                            if let duration = entry.duration {
                                Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                            }
                        }.font(.caption)
                    }
                    .contextMenu {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.command }
                        Button("Insert", systemImage: "text.insert") {
                            dismiss()
                            workspace.insertHistory(entry.command)
                        }.disabled(!workspace.connected)
                        Button("Delete", role: .destructive) { workspace.commandHistory.delete(entry.id) }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { workspace.commandHistory.delete(entry.id) } }
                }
                if let error = workspace.commandHistory.storageError { Text(error).foregroundStyle(.red) }
            }
            .searchable(text: $query)
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Clear", role: .destructive) { clearing = true } }
            }
            .confirmationDialog("Clear History?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Clear", role: .destructive) { workspace.commandHistory.clear(for: workspace.descriptor.hostID) }
            }
        }.presentationDetents([.medium, .large])
            .onDisappear { workspace.terminal.requestFocus() }
    }
}
