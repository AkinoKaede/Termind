import SwiftUI
import TermindDomain

/// The persisted tag palette shared by Vault editors on both platforms.
public struct ColorTagPicker: View {
    public enum Layout { case compact, touch }
    @Binding private var selection: TagColor
    private let layout: Layout

    public init(selection: Binding<TagColor>, layout: Layout) {
        _selection = selection
        self.layout = layout
    }

    public var body: some View {
        Group {
            if layout == .compact {
                HStack(spacing: 8) { swatches }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 52), spacing: 4)], spacing: 8) {
                    swatches
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppStrings.Vault.color.swiftUIKey)
    }

    private var swatches: some View {
        ForEach(TagColor.allCases) { color in
            Button {
                selection = color
            } label: {
                Swatch(color: color, isSelected: selection == color, layout: layout)
                    .frame(minWidth: layout == .touch ? 44 : nil, minHeight: layout == .touch ? 44 : nil)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(color.displayName))
            .accessibilityLabel(Text(color.displayName))
            .accessibilityAddTraits(selection == color ? [.isButton, .isSelected] : .isButton)
        }
    }

    private struct Swatch: View {
        let color: TagColor
        let isSelected: Bool
        let layout: Layout

        var body: some View {
            ZStack {
                if let fill = color.color {
                    Circle().fill(fill)
                } else {
                    Image(systemName: "circle.dashed").resizable().fontWeight(.light).foregroundStyle(.secondary)
                }
            }
            .frame(width: layout == .compact ? 20 : 26, height: layout == .compact ? 20 : 26)
            .overlay {
                if isSelected {
                    let foreground = selectionForeground
                    ZStack {
                        Circle().strokeBorder(foreground, lineWidth: 1.5).padding(2)
                        Image(systemName: "checkmark")
                            .font(.system(size: layout == .compact ? 9 : 12, weight: .bold))
                            .foregroundStyle(foreground)
                    }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
        }

        private var selectionForeground: Color {
            color == .none ? .primary : .white
        }
    }
}
