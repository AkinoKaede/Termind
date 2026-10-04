import SwiftUI

/// Form values keep their own wrapping height instead of compressing the field name.
struct TailscaleFormRow<Content: View>: View {
    let label: LocalizedStringResource
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Group {
                if let symbol {
                    Label(label.swiftUIKey, systemImage: symbol)
                } else {
                    Text(label)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            content
                .font(.system(.caption, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// Machine identifiers must not acquire keyboard substitutions on mobile.
    func tailscaleIdentifierInput() -> some View {
        self
            .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
    }
}
