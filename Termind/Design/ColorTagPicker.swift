import SwiftUI

/// A row of color swatches for picking a `HostColor`.
///
/// A control rather than a `Picker`, because on macOS a `Picker` inside a `Form`
/// renders as a pop-up menu and AppKit templates the images in menu items — the
/// symbol comes out in the menu's text color no matter what `.foregroundStyle`
/// says. So a colour picker built that way shows nine identical grey circles and
/// the one thing it exists to communicate is the one thing it cannot. Drawing
/// the swatches directly is what makes the color visible.
///
/// Lives in `Design/` rather than beside the host editor: it is a swatch row over
/// `HostColor` and knows nothing about what is being tagged.
struct ColorTagPicker: View {
    @Binding var selection: HostColor

    /// Large enough to read as a color at a glance and to hit without aiming;
    /// the ring is drawn outside it, so the row is taller than the swatch.
    private let swatch: CGFloat = 20

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            ForEach(HostColor.allCases) { color in
                swatchButton(color)
            }
        }
        // The whole row is one control to VoiceOver, so it is reached with a
        // single Tab stop like the picker it replaces.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Color"))
    }

    private func swatchButton(_ color: HostColor) -> some View {
        Button {
            selection = color
        } label: {
            ZStack {
                if let fill = color.color {
                    Circle().fill(fill)
                } else {
                    // "No color" as an outline rather than a grey fill, so it
                    // reads as absence instead of as a ninth color.
                    Image(systemName: "circle.dashed")
                        .resizable()
                        .fontWeight(.light)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: swatch, height: swatch)
            .overlay {
                Circle()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3)
                    .opacity(selection == color ? 1 : 0)
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(Text(color.displayName))
        .accessibilityLabel(Text(color.displayName))
        .accessibilityAddTraits(selection == color ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    @Previewable @State var selection: HostColor = .teal

    Form {
        LabeledContent("Color") {
            ColorTagPicker(selection: $selection)
        }
    }
    .formStyle(.grouped)
    .frame(width: 420)
}
