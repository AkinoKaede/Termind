import SwiftUI

/// One attachment recovered from a composed user turn.
///
/// `ConversationModel.composed(_:)` folds each chip into the message body as
/// `<kind label="…">…</kind>` so that what was uploaded is literally what the
/// transcript holds. Foundation's Markdown parser hands that back as a single
/// untouched HTML block — verbatim, down to characters like `*` that emphasis
/// would otherwise eat — which is what makes recognising it here safe.
///
/// The grammar lives on this side of the fence on purpose: the tag vocabulary
/// is `ContextChip.Kind`'s, and the parser must not depend on presentation state.
struct AttachmentBlock: Hashable {
    var kind: ContextChip.Kind
    var label: String
    var content: String

    static func parse(_ raw: String) -> AttachmentBlock? {
        let lines = raw.components(separatedBy: "\n")
        guard
            let openIndex = lines.firstIndex(where: { !$0.trimmed.isEmpty }),
            let closeIndex = lines.lastIndex(where: { !$0.trimmed.isEmpty }),
            openIndex < closeIndex
        else { return nil }

        let open = lines[openIndex].trimmed
        guard open.hasPrefix("<"), open.hasSuffix(">"), !open.hasPrefix("</") else { return nil }

        let body = open.dropFirst().dropLast()
        guard let separator = body.firstIndex(of: " ") else { return nil }
        let tag = String(body[body.startIndex..<separator])

        guard lines[closeIndex].trimmed == "</\(tag)>" else { return nil }
        guard let kind = ContextChip.Kind.allCases.first(where: { $0.blockName == tag }) else {
            return nil
        }

        let attributes = String(body[body.index(after: separator)...]).trimmed
        guard attributes.hasPrefix(#"label=""#), attributes.hasSuffix("\"") else { return nil }
        let label = String(attributes.dropFirst(7).dropLast())

        return AttachmentBlock(
            kind: kind,
            label: label,
            content: lines[(openIndex + 1)..<closeIndex].joined(separator: "\n")
        )
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

/// The folded form of an attachment inside a user bubble.
///
/// Folded rather than laid out in full: a two-hundred-line log printed into a
/// right-aligned bubble is not readable by anyone. The payload is one click
/// away and unaltered, so `composed(_:)`'s promise that the bubble shows what
/// was uploaded still holds.
struct MarkdownAttachmentView: View {
    let attachment: AttachmentBlock

    @State private var isExpanded = false
    @Environment(\.markdownFillsWidth) private var fillsWidth

    private var lineCount: Int {
        attachment.content.isEmpty ? 0 : attachment.content.components(separatedBy: "\n").count
    }

    private var sizeLabel: String {
        lineCount == 1 ? String(localized: "1 line") : String(localized: "\(lineCount) lines")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: Metrics.Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    Image(systemName: attachment.kind.symbol)
                        .font(.caption)
                    Text(attachment.label)
                        .font(.callout)
                        // No `textSelection` here, deliberately: a click that
                        // starts a selection in truncated text drags it out of
                        // the bubble it belongs to.
                        .lineLimit(1)
                    Text(sizeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // No trailing `Spacer` — inside a bubble it would be greedy and
                // stretch the bubble to the full column for a one-word label.
                .markdownWidth(fills: fillsWidth)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(isExpanded ? "Hide attached content" : "Show attached content"))

            if isExpanded {
                Text(attachment.content)
                    .font(MarkdownTypography.monospaced)
                    .textSelection(.enabled)
                    .markdownWidth(fills: fillsWidth)
            }
        }
    }
}
