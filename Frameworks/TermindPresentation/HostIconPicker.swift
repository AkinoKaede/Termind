import SwiftUI
import TermindDomain

public struct HostIconPicker: View {
    @Environment(\.displayScale) private var displayScale
    @Binding private var selection: String?
    private let detectedDistribution: DetectedDistribution?

    public init(selection: Binding<String?>, detectedDistribution: DetectedDistribution?) {
        _selection = selection
        self.detectedDistribution = detectedDistribution
    }

    public var body: some View {
        LabeledContent(AppStrings.Vault.icon.swiftUIKey) {
            Menu {
                // Picker flattens internal sections; separate pickers preserve native menu dividers.
                Picker(AppStrings.Vault.icon.swiftUIKey, selection: $selection) {
                    iconLabel(Text(AppStrings.Common.automatic), artwork: artwork(for: nil))
                        .tag(String?.none)
                }
                .labelsHidden()
                Divider()
                Picker(AppStrings.Vault.icon.swiftUIKey, selection: $selection) {
                    ForEach(HostGeneralIcon.allCases) { icon in
                        iconLabel(Text(icon.title), artwork: .systemImage(icon.systemImageName))
                            .tag(String?.some(icon.id))
                    }
                }
                .labelsHidden()
                Divider()
                Picker(AppStrings.Vault.icon.swiftUIKey, selection: $selection) {
                    ForEach(HostIconCatalog.bundled.selectableEntries) { entry in
                        iconLabel(Text(verbatim: entry.title), artwork: .asset(entry.asset))
                            .tag(String?.some(entry.id))
                    }
                    if let selection, HostGeneralIcon(rawValue: selection) == nil,
                        !HostIconCatalog.bundled.entries.contains(where: { $0.id == selection })
                    {
                        iconLabel(Text(AppStrings.Vault.unknownIcon), artwork: artwork(for: selection))
                            .tag(String?.some(selection))
                    }
                }
                .labelsHidden()
            } label: {
                iconLabel(selectionTitle, artwork: artwork(for: selection))
            }
            .pickerStyle(.inline)
            .menuOrder(.fixed)
            .accessibilityLabel(Text(AppStrings.Vault.icon))
            .accessibilityValue(selectionTitle)
            .accessibilityIdentifier("hostIcon.picker")
            #if os(macOS)
                .menuStyle(.borderlessButton)
            #endif
        }
    }

    private var selectionTitle: Text {
        guard let selection else { return Text(AppStrings.Common.automatic) }
        if let icon = HostGeneralIcon(rawValue: selection) { return Text(icon.title) }
        if let entry = HostIconCatalog.bundled.entries.first(where: { $0.id == selection }) {
            return Text(verbatim: entry.title)
        }
        return Text(AppStrings.Vault.unknownIcon)
    }

    private func artwork(for overrideID: String?) -> HostIconArtwork {
        HostIconCatalog.bundled.resolvedArtwork(overrideID: overrideID, distribution: detectedDistribution)
    }

    private func iconLabel(_ title: Text, artwork: HostIconArtwork) -> some View {
        Label {
            title.lineLimit(1)
        } icon: {
            menuImage(for: artwork).resizable().scaledToFit().frame(width: 16, height: 16)
        }
        .labelStyle(.titleAndIcon)
    }

    private func menuImage(for artwork: HostIconArtwork) -> Image {
        #if os(macOS)
            // Native menus extract the underlying image and ignore SwiftUI's frame.
            if artwork.assetName != nil {
                let renderer = ImageRenderer(
                    content: artwork.image.resizable().scaledToFit().frame(width: 16, height: 16))
                renderer.scale = displayScale
                if let image = renderer.cgImage {
                    return Image(decorative: image, scale: displayScale).renderingMode(.template)
                }
            }
        #endif
        return artwork.image
    }
}
