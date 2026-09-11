import SwiftUI
import TermindDomain

struct MobileSnippetsView: View {
    let app: MobileAppModel
    @State private var editing: Snippet?
    @State private var query = ""

    var body: some View {
        List(app.snippets.searchSnippets(query)) { snippet in
            Button {
                editing = snippet
            } label: {
                VStack(alignment: .leading) {
                    Text(snippet.title)
                    Text(snippet.body).font(.caption.monospaced()).lineLimit(2).foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $query)
        .navigationTitle("Snippets")
        .toolbar { Button("New Snippet", systemImage: "plus") { editing = Snippet(title: "", body: "") } }
        .sheet(item: $editing) { MobileSnippetEditor(app: app, snippet: $0) }
    }
}

private struct MobileSnippetEditor: View {
    let app: MobileAppModel
    let original: Snippet
    @State private var draft: Snippet

    init(app: MobileAppModel, snippet: Snippet) {
        self.app = app
        original = snippet
        _draft = State(initialValue: snippet)
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "Snippet"), isDirty: draft != original,
            canSave: !draft.title.isEmpty && !draft.body.isEmpty,
            save: {
                app.snippets.upsert(draft)
                if let error = app.library.storageError { throw MobileEditorError.message(error) }
            },
            content: {
                TextField("Title", text: $draft.title)
                TextEditor(text: $draft.body).multilineTextAlignment(.leading).font(.body.monospaced()).frame(
                    minHeight: 220
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            })
    }
}
