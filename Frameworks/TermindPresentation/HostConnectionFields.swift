import SwiftUI
import TermindDomain

import struct TermindDomain.Host

/// The same connection form inside a desktop work column or a mobile sheet.
public struct HostConnectionFields: View {
    @Binding private var host: Host

    public init(host: Binding<Host>) { _host = host }

    public var body: some View {
        Section("Connection") {
            LabeledContent("Name") {
                TextField("Name", text: $host.name.singleLineText, prompt: Text(host.host), axis: .horizontal)
                    .singleLinePaste()
                    .lineLimit(1).labelsHidden().multilineTextAlignment(
                        .trailing)
            }
            LabeledContent("Host") {
                TextField(
                    "Host", text: $host.host.singleLineText, prompt: Text("IP address or hostname"), axis: .horizontal
                ).singleLinePaste().lineLimit(1)
                    .labelsHidden().multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    #endif
            }
            LabeledContent("Port") {
                TextField("Port", value: $host.port, format: .number.grouping(.never)).lineLimit(1)
                    .labelsHidden().multilineTextAlignment(.trailing)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
            }
        }
        Section("SFTP") {
            LabeledContent("Initial Path") {
                TextField(
                    "Initial Path", text: $host.sftpSessionInitialPath.singleLineText, prompt: Text("~"),
                    axis: .horizontal
                ).singleLinePaste().lineLimit(1)
                    .labelsHidden().multilineTextAlignment(.trailing)
                    .font(.body.monospaced())
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    #endif
            }
            Text("Leave blank for the remote home directory, or enter an absolute path.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
