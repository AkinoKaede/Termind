import SwiftUI
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

#if os(iOS)
    /// The mobile sheet supplies navigation chrome around the shared diagnostics.
    public struct TailscalePeerView: View {
        let model: TailscaleModel
        let host: Host
        let copy: (String) -> Void
        @Environment(\.dismiss) private var dismiss

        public init(model: TailscaleModel, host: Host, copy: @escaping (String) -> Void) {
            self.model = model
            self.host = host
            self.copy = copy
        }

        public var body: some View {
            NavigationStack {
                TailscalePeerForm(model: model, host: host, copy: copy)
                    .navigationTitle(AppStrings.Tailscale.title.swiftUIKey)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button(AppStrings.Common.close.swiftUIKey, systemImage: "xmark") { dismiss() }
                                .labelStyle(.iconOnly)
                                .keyboardShortcut(.cancelAction)
                                .accessibilityIdentifier("tailscale.close")
                        }
                    }
            }
        }
    }

#endif
