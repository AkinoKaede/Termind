import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

import struct TermindDomain.Host

struct MobileHostEditor: View {
    let library: HostLibraryModel
    let original: Host
    @State private var draft: Host

    init(library: HostLibraryModel, host: Host) {
        self.library = library
        original = host
        _draft = State(initialValue: host)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Host"), isDirty: draft != original,
            canSave: !draft.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (1...65535).contains(draft.port),
            save: {
                if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft.name = draft.host }
                _ = library.upsert(draft, replacingPortForwardings: library.portForwardings(for: draft.id))
                if let error = library.storageError { throw MobileEditorError.message(error) }
            },
            content: {
                HostConnectionFields(host: $draft)
                Section("Authentication") {
                    Picker("Identity", selection: $draft.identityID) {
                        Text("None").tag(UUID?.none)
                        ForEach(library.identities) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("Routing") {
                    Picker("Jump Host", selection: $draft.jumpHostID) {
                        Text("None").tag(UUID?.none)
                        ForEach(library.hosts.filter { $0.id != draft.id }) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section("Group") {
                    Picker("Group", selection: $draft.groupID) {
                        Text("None").tag(UUID?.none)
                        ForEach(library.groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            })
    }
}

nonisolated enum MobileEditorError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let value): value
        }
    }
}
