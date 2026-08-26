import SwiftUI

/// One attachment recovered from a composed user turn.
///
/// `ConversationModel.composed(_:)` folds each chip into the message body as
/// `<kind label="…">…</kind>` so the model-facing transcript retains the
/// payload. Foundation's Markdown parser hands that back as a single
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

/// A compact fallback for attachment markup stored by older builds.
///
/// New user bubbles are projected from the original prompt and never reach
/// this view. Keeping the fallback non-expandable prevents a legacy PDF or
/// pasted-text payload from producing an enormous SwiftUI text tree.
struct MarkdownAttachmentView: View {
    let attachment: AttachmentBlock

    @Environment(\.markdownFillsWidth) private var fillsWidth

    var body: some View {
        HStack(spacing: Metrics.Space.xs) {
            Image(systemName: attachment.kind.symbol)
                .font(.caption)
            Text(attachment.label)
                .font(.callout)
                .lineLimit(1)
        }
        .markdownWidth(fills: fillsWidth)
        .accessibilityElement(children: .combine)
    }
}
