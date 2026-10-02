import SwiftUI

struct TailscaleCopyField: View {
    let label: LocalizedStringResource
    let value: String
    let copy: (String) -> Void
    @State private var copied = false
    @State private var copyID = UUID()

    var body: some View {
        if !value.isEmpty {
            LabeledContent(label.swiftUIKey) {
                HStack {
                    Text(verbatim: value)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                    Button {
                        copy(value)
                        copied = true
                        copyID = UUID()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel((copied ? AppStrings.Common.copied : AppStrings.Common.copy).swiftUIKey)
                    .task(id: copyID) {
                        guard copied else { return }
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        copied = false
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
