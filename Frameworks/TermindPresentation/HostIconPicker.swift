// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
        #if os(macOS)
            Picker(AppStrings.Vault.icon.swiftUIKey, selection: $selection) {
                automaticOption
                Divider()
                generalOptions
                Divider()
                distributionOptions
            }
            .accessibilityIdentifier("hostIcon.picker")
        #else
            LabeledContent(AppStrings.Vault.icon.swiftUIKey) {
                Menu {
                    // Picker flattens internal sections; separate pickers preserve native menu dividers.
                    Picker(AppStrings.Vault.icon.swiftUIKey, selection: $selection) {
                        automaticOption
                    }
                    .labelsHidden()
                    Divider()
                    Picker(AppStrings.Vault.icon.swiftUIKey, selection: $selection) {
                        generalOptions
                    }
                    .labelsHidden()
                    Divider()
                    Picker(AppStrings.Vault.icon.swiftUIKey, selection: $selection) {
                        distributionOptions
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
            }
        #endif
    }

    private var automaticOption: some View {
        iconLabel(Text(AppStrings.Common.automatic), artwork: artwork(for: nil))
            .tag(String?.none)
    }

    private var generalOptions: some View {
        ForEach(HostGeneralIcon.allCases) { icon in
            iconLabel(Text(icon.title), artwork: .systemImage(icon.systemImageName))
                .tag(String?.some(icon.id))
        }
    }

    @ViewBuilder
    private var distributionOptions: some View {
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
