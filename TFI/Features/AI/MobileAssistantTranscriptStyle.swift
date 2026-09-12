import MarkdownView
import SwiftUI
import TermindPresentation
import UIKit

struct MobileAssistantMarkdown: View {
    let text: String
    var secondary = false
    @ScaledMetric private var bodySize: CGFloat = 17
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AssistantMessageBody(text, theme: theme).textSelection(.enabled)
    }

    private var theme: MarkdownTheme {
        var value = MarkdownTheme()
        value.fonts.body = .systemFont(ofSize: bodySize)
        value.fonts.bold = .boldSystemFont(ofSize: bodySize)
        value.fonts.italic = .italicSystemFont(ofSize: bodySize)
        value.fonts.codeInline = .monospacedSystemFont(ofSize: bodySize, weight: .regular)
        value.fonts.code = .monospacedSystemFont(ofSize: ceil(bodySize * MarkdownTheme.codeScale), weight: .regular)
        value.fonts.title = .boldSystemFont(ofSize: bodySize + 2)
        value.fonts.largeTitle = .boldSystemFont(ofSize: bodySize + 5)
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let color = (secondary ? UIColor.secondaryLabel : .label).resolvedColor(with: traits)
        value.colors.body = color
        value.colors.code = color
        value.colors.highlight = UIColor(named: "AccentColor") ?? .systemBlue
        value.colors.emphasis = UIColor(named: "AccentColor") ?? .systemBlue
        value.colors.codeBackground = UIColor.secondaryLabel.resolvedColor(with: traits).withAlphaComponent(0.15)
        value.spacings.paragraph = AssistantTranscriptStyle.blockSpacing
        value.spacings.headingBefore = 4
        value.spacings.list = 4
        value.table.cornerRadius = 4
        value.table.borderColor = UIColor.separator.resolvedColor(with: traits)
        value.table.headerBackgroundColor = UIColor.quaternaryLabel.resolvedColor(with: traits).withAlphaComponent(0.12)
        value.table.stripeCellBackgroundColor = UIColor.quaternaryLabel.resolvedColor(with: traits).withAlphaComponent(
            0.06)
        return value
    }
}

struct MobileAssistantScanning: ViewModifier {
    let active: Bool
    @Environment(\.mobileListRowIsDisplayed) private var displayed
    @Environment(\.mobileListReduceMotion) private var reduceMotion
    @Environment(\.mobileListSceneIsActive) private var sceneIsActive

    func body(content: Content) -> some View {
        if active && displayed && !reduceMotion && sceneIsActive {
            content.mask {
                TimelineView(.animation) { context in
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let band = AssistantTranscriptStyle.scanBandWidth(for: width)
                        let phase =
                            context.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: AssistantTranscriptStyle.scanDuration)
                            / AssistantTranscriptStyle.scanDuration
                        ZStack(alignment: .leading) {
                            Color.white
                            LinearGradient(
                                colors: AssistantTranscriptStyle.scanAlphas.map { Color.white.opacity($0) },
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: band)
                            .offset(x: -band + (width + band) * phase)
                            .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                }
            }
        } else {
            content
        }
    }
}

struct MobileAssistantActivity: View {
    var cyclesText = false
    @State private var startedAt = Date.now
    @Environment(\.mobileListRowIsDisplayed) private var displayed
    @Environment(\.mobileListReduceMotion) private var reduceMotion
    @Environment(\.mobileListSceneIsActive) private var sceneIsActive

    var body: some View {
        Group {
            if cyclesText && displayed && !reduceMotion && sceneIsActive {
                TimelineView(.animation(minimumInterval: AssistantTranscriptStyle.activityTextDuration)) { context in
                    let titles: [LocalizedStringKey] = ["Working…", "Thinking…", "Reasoning…"]
                    let index =
                        max(
                            0,
                            Int(
                                context.date.timeIntervalSince(startedAt)
                                    / AssistantTranscriptStyle.activityTextDuration)) % titles.count
                    Text(titles[index])
                }
            } else {
                Text("Working…")
            }
        }
        .foregroundStyle(.secondary)
        .modifier(MobileAssistantScanning(active: true))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MobileAssistantDisclosure<Title: View, Content: View>: View {
    let expanded: Bool
    let toggle: () -> Void
    @ViewBuilder var title: () -> Title
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    title().frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? Text("Hide details") : Text("Show details"))
            if expanded { content() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
