import SwiftUI

public struct HostIconPicker: View {
    @Binding private var selection: String?

    public init(selection: Binding<String?>) {
        _selection = selection
    }

    public var body: some View {
        Picker(AppStrings.Vault.icon.swiftUIKey, selection: $selection) {
            Label(AppStrings.Common.automatic.swiftUIKey, systemImage: "sparkles").tag(String?.none)
            Label(AppStrings.Vault.serverIcon.swiftUIKey, systemImage: "server.rack").tag(String?.some("server"))
            Divider()
            ForEach(HostIconCatalog.bundled.selectableEntries) { entry in
                Label {
                    Text(verbatim: entry.title)
                } icon: {
                    Image(entry.asset, bundle: .main).resizable().scaledToFit().frame(width: 16, height: 16)
                }
                .tag(String?.some(entry.id))
            }
            if let selection, selection != "server",
                !HostIconCatalog.bundled.entries.contains(where: { $0.id == selection })
            {
                Label(AppStrings.Vault.unknownIcon.swiftUIKey, systemImage: "questionmark.square")
                    .tag(String?.some(selection))
            }
        }
        .pickerStyle(.menu)
        .menuOrder(.fixed)
    }
}
