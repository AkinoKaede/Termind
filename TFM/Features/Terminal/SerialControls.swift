import SwiftUI
import TermindPresentation

nonisolated struct SerialComboOption: Identifiable, Hashable, Sendable {
    let value: String
    let label: String
    var id: String { value }
}

/// An editable value and its known presets in one control. Serial paths and
/// baud rates both need this shape: discovery is helpful, but must never make a
/// driver-specific value impossible to type.
struct SerialEditableComboField: View {
    let title: LocalizedStringResource
    @Binding var value: String
    let options: [SerialComboOption]
    var monospaced = true
    @State private var presentsOptions = false

    var body: some View {
        LabeledContent {
            HStack(spacing: 0) {
                TextField("", text: $value.singleLineText, axis: .horizontal).singleLinePaste().lineLimit(1)
                    .textFieldStyle(.plain)
                    .font(monospaced ? .body.monospaced() : .body)
                    .padding(.leading, Metrics.Space.m)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(title)

                Rectangle()
                    .fill(.quaternary.opacity(0.75))
                    .frame(width: 1, height: 14)

                Button {
                    presentsOptions.toggle()
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .termindInputAwareFocusEffect()
                .fixedSize()
                // Arrow on the popover's top edge keeps the option list below
                // the editable field instead of letting NSMenu align it beside
                // the current value.
                .popover(
                    isPresented: $presentsOptions,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    optionList
                        .presentationCompactAdaptation(.popover)
                }
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 360, minHeight: 22, maxHeight: 22)
            .background(
                .quaternary.opacity(0.22),
                in: .rect(cornerRadius: Metrics.Radius.medium)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.Radius.medium)
                    .stroke(.quaternary.opacity(0.55), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            // LabeledContent aligns its two columns on firstTextBaseline. Make
            // that baseline the visual centre of the custom control so it
            // agrees with native Picker rows without replacing LabeledContent.
            .alignmentGuide(.firstTextBaseline) { dimensions in
                dimensions[VerticalAlignment.center]
            }
        } label: {
            Text(title)
                .frame(height: 22, alignment: .center)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[VerticalAlignment.center]
                }
        }
    }

    private var optionList: some View {
        ScrollView {
            LazyVStack(spacing: Metrics.Space.xxs) {
                if options.isEmpty {
                    Text(AppStrings.Terminal.noDetectedSerialDevices)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Metrics.Space.m)
                } else {
                    ForEach(options) { option in
                        Button {
                            value = option.value
                            presentsOptions = false
                        } label: {
                            HStack(spacing: Metrics.Space.m) {
                                Image(systemName: "checkmark")
                                    .frame(width: 12)
                                    .opacity(option.value == value ? 1 : 0)
                                Text(option.label)
                                    .font(monospaced ? .body.monospaced() : .body)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Metrics.Space.m)
                            .frame(height: 30)
                            .contentShape(.rect)
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .termindInputAwareFocusEffect()
                    }
                }
            }
            .padding(Metrics.Space.xs)
        }
        .frame(width: 360)
        .frame(minHeight: 38, maxHeight: 260)
    }
}
