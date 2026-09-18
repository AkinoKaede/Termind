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
        .accessibilityLabel("Color")
    }

    private var swatches: some View {
        ForEach(TagColor.allCases) { color in
            Button {
                selection = color
            } label: {
                ZStack {
                    if let fill = color.color {
                        Circle().fill(fill)
                    } else {
                        Image(systemName: "circle.dashed").resizable().fontWeight(.light).foregroundStyle(.secondary)
                    }
                    if layout == .touch && selection == color {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary).padding(3).background(.background, in: .circle)
                    }
                }
                .frame(width: layout == .compact ? 20 : 26, height: layout == .compact ? 20 : 26)
                .overlay {
                    Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                        .opacity(selection == color ? 1 : 0)
                }
                .frame(minWidth: layout == .touch ? 44 : nil, minHeight: layout == .touch ? 44 : nil)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(color.displayName))
            .accessibilityLabel(Text(color.displayName))
            .accessibilityAddTraits(selection == color ? [.isButton, .isSelected] : .isButton)
        }
    }
}
