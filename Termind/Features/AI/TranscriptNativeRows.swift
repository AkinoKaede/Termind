import AppKit
import ListViewKit
import MarkdownView

@MainActor
final class TranscriptMarkdownCache {
    final class Package {
        let source: String
        let rendered: TermindMarkdownRenderedDocument

        init(source: String, allowsShellActions: Bool, tone: TermindMarkdownView.Tone) {
            self.source = source
            rendered = TermindMarkdownRenderedDocument(
                source: source,
                allowsShellActions: allowsShellActions,
                theme: TermindMarkdownTheme.make(tone: tone)
            )
        }
    }

    private struct Key: Hashable {
        let entryID: UUID
        let slot: String
        let source: String
        let shell: Bool
        let tone: TermindMarkdownView.Tone
    }

    private let limit: Int
    private var values: [Key: Package] = [:]
    private var order: [Key] = []

    init(limit: Int) { self.limit = limit }

    func package(
        entryID: UUID,
        slot: String,
        source: String,
        shell: Bool,
        tone: TermindMarkdownView.Tone = .primary
    ) -> Package {
        let key = Key(entryID: entryID, slot: slot, source: source, shell: shell, tone: tone)
        if let value = values[key] {
            touch(key)
            return value
        }
        let value = Package(source: source, allowsShellActions: shell, tone: tone)
        values[key] = value
        touch(key)
        while order.count > limit { values[order.removeFirst()] = nil }
        return value
    }

    func prune(validEntryIDs: Set<UUID>) {
        let stale = values.keys.filter { !validEntryIDs.contains($0.entryID) }
        guard !stale.isEmpty else { return }
        let set = Set(stale)
        for key in stale { values[key] = nil }
        order.removeAll { set.contains($0) }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

@MainActor
final class TranscriptRowSizingPool {
    private struct Key: Hashable {
        let id: UUID
        let value: TranscriptEntry
        let width: Int
        let compact: Bool
        let revision: UInt64
    }

    private let limit: Int
    private var rows: [UUID: TranscriptNativeRow] = [:]
    private var order: [UUID] = []
    private var heights: [Key: CGFloat] = [:]

    init(limit: Int) { self.limit = limit }

    func height(
        for entry: TranscriptEntry,
        width: CGFloat,
        configuration: TranscriptListConfiguration,
        presentation: TranscriptPresentationState,
        configure: (TranscriptNativeRow) -> Void
    ) -> CGFloat {
        let key = Key(
            id: entry.id,
            value: entry,
            width: Int((width * 2).rounded()),
            compact: configuration.isCompact,
            revision: presentation.layoutRevision(for: entry.presentationIDs)
        )
        if let height = heights[key] { return height }
        let row = rows[entry.id] ?? TranscriptNativeRow.make(for: entry.kind)
        rows[entry.id] = row
        touch(entry.id)
        configure(row)
        let height = max(1, ceil(row.measuredHeight(for: width)))
        heights[key] = height
        while order.count > limit {
            let id = order.removeFirst()
            rows[id] = nil
            heights = heights.filter { $0.key.id != id }
        }
        return height
    }

    func invalidate(_ id: UUID) { heights = heights.filter { $0.key.id != id } }
    func prune(validEntryIDs: Set<UUID>) {
        let stale = rows.keys.filter { !validEntryIDs.contains($0) }
        guard !stale.isEmpty else { return }
        let set = Set(stale)
        for id in stale { rows[id] = nil }
        order.removeAll { set.contains($0) }
        heights = heights.filter { !set.contains($0.key.id) }
    }
    func removeAll() {
        rows.removeAll()
        order.removeAll()
        heights.removeAll()
    }
    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}

@MainActor
class TranscriptNativeRow: ListRowView {
    private let root = NativeStack.vertical(spacing: Metrics.Space.s)
    private var widthConstraint: NSLayoutConstraint?
    private var configuration: TranscriptListConfiguration?
    private var topInset: CGFloat = 0
    private var representedID: UUID?
    private var activeContent: NSView?
    private var hoverViews: [NSView] = []
    private var isHovering = false
    private var tracking: NSTrackingArea?

    static func make(for kind: TranscriptEntry.Kind) -> TranscriptNativeRow {
        switch kind {
        case .empty: TranscriptEmptyRow()
        case .user: TranscriptUserRow()
        case .assistant: TranscriptAssistantRow()
        case .tool: TranscriptToolRow()
        case .work: TranscriptWorkRow()
        case .plan: TranscriptPlanRow()
        case .compaction: TranscriptCompactionRow()
        case .compactionActivity: TranscriptCompactionActivityRow()
        case .interrupted: TranscriptInterruptedRow()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetHoverState()
        root.removeAllArrangedSubviews()
        representedID = nil
        activeContent = nil
        hoverViews.removeAll()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
    }

    func configure(
        entry: TranscriptEntry,
        proposedWidth: CGFloat,
        configuration: TranscriptListConfiguration,
        actions: TranscriptListActions,
        presentation: TranscriptPresentationState,
        markdownCache: TranscriptMarkdownCache,
        measurement: Bool,
        invalidate: @escaping (UUID, Bool) -> Void
    ) {
        self.configuration = configuration
        topInset = entry.hasLeadingSpacing ? Metrics.Chat.turnSpacing : 0
        let contentWidth = max(
            1,
            min(
                proposedWidth - configuration.horizontalInset * 2,
                configuration.isCompact ? .greatestFiniteMagnitude : Metrics.Chat.contentMaxWidth
            )
        )
        let context = NativeTranscriptContext(
            entryID: entry.id,
            contentWidth: contentWidth,
            configuration: configuration,
            actions: actions,
            presentation: presentation,
            markdownCache: markdownCache,
            measurement: measurement,
            invalidate: invalidate,
            registerHoverView: { [weak self] view in
                guard !measurement else { return }
                guard let self else { return }
                hoverViews.append(view)
                view.alphaValue = isHovering ? 1 : 0
            },
            presentError: { [weak self] title, message in
                guard !measurement else { return }
                self?.presentError(title: title, message: message)
            }
        )
        if representedID == entry.id, let activeContent {
            hoverViews.removeAll()
            if NativeTranscriptFactory.update(activeContent, for: entry, context: context) {
                synchronizeHoverWithPointer()
                return
            }
        }
        let content = NativeTranscriptFactory.view(for: entry, context: context)
        representedID = entry.id
        activeContent = content
        root.removeAllArrangedSubviews()
        if topInset > 0 { root.addArrangedSubview(NativeSpacer(height: topInset)) }
        let centered = NSView()
        centered.translatesAutoresizingMaskIntoConstraints = false
        centered.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: centered.topAnchor),
            content.bottomAnchor.constraint(equalTo: centered.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: centered.centerXAnchor),
            content.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        root.addArrangedSubview(centered)
        centered.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        synchronizeHoverWithPointer()
    }

    func measuredHeight(for width: CGFloat) -> CGFloat {
        widthConstraint?.isActive = false
        let constraint = widthAnchor.constraint(equalToConstant: width)
        constraint.isActive = true
        widthConstraint = constraint
        layoutSubtreeIfNeeded()
        let value = fittingSize.height
        constraint.isActive = false
        widthConstraint = nil
        return value
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        var options: NSTrackingArea.Options = [
            .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited,
        ]
        if currentPointerIsInside == true { options.insert(.assumeInside) }
        let area = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
        synchronizeHoverWithPointer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            resetHoverState()
            return
        }
        synchronizeHoverWithPointer()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHoverVisible(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoverVisible(false)
    }

    private func setHoverVisible(_ visible: Bool) {
        guard isHovering != visible else { return }
        isHovering = visible
        NSAnimationContext.runAnimationGroup { context in
            context.duration = configuration?.reduceMotion == true ? 0 : 0.12
            for view in hoverViews { view.animator().alphaValue = visible ? 1 : 0 }
        }
    }

    private func synchronizeHoverWithPointer() {
        guard let currentPointerIsInside else { return }
        setHoverVisible(currentPointerIsInside)
    }

    private var currentPointerIsInside: Bool? {
        guard let window else { return nil }
        guard window.isKeyWindow, !isHidden else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return visibleRect.contains(point)
    }

    private func resetHoverState() {
        isHovering = false
        for view in hoverViews { view.alphaValue = 0 }
    }

    private func presentError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

@MainActor final class TranscriptEmptyRow: TranscriptNativeRow {}
@MainActor final class TranscriptUserRow: TranscriptNativeRow {}
@MainActor final class TranscriptAssistantRow: TranscriptNativeRow {}
@MainActor final class TranscriptToolRow: TranscriptNativeRow {}
@MainActor final class TranscriptWorkRow: TranscriptNativeRow {}
@MainActor final class TranscriptPlanRow: TranscriptNativeRow {}
@MainActor final class TranscriptCompactionRow: TranscriptNativeRow {}
@MainActor final class TranscriptCompactionActivityRow: TranscriptNativeRow {}
@MainActor final class TranscriptInterruptedRow: TranscriptNativeRow {}

@MainActor
private struct NativeTranscriptContext {
    let entryID: UUID
    let contentWidth: CGFloat
    let configuration: TranscriptListConfiguration
    let actions: TranscriptListActions
    let presentation: TranscriptPresentationState
    let markdownCache: TranscriptMarkdownCache
    let measurement: Bool
    let invalidate: (UUID, Bool) -> Void
    let registerHoverView: (NSView) -> Void
    let presentError: (String, String) -> Void
}

@MainActor
private enum NativeTranscriptFactory {
    private final class AssistantContent: NSView {
        private let stack = NativeStack.vertical(spacing: Metrics.Chat.blockSpacing)
        private let markdownView = NativeMarkdownView()
        private var representedMessageID: UUID?

        override init(frame: CGRect) {
            super.init(frame: frame)
            markdownView.identifier = NSUserInterfaceItemIdentifier(
                "Transcript.AssistantMarkdown"
            )
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func configure(
            message: ChatMessage,
            canFork: Bool,
            context: NativeTranscriptContext
        ) {
            let sameMessage = representedMessageID == message.id
            representedMessageID = message.id
            stack.removeAllArrangedSubviews()
            if !message.text.isEmpty {
                markdownView.configure(
                    package: context.markdownCache.package(
                        entryID: context.entryID,
                        slot: "assistant",
                        source: message.text,
                        shell: true
                    ),
                    measurement: context.measurement,
                    proposedWidth: context.contentWidth,
                    fillsWidth: true,
                    actions: .init(
                        enabled: context.configuration.showsTerminalActions
                            && context.actions.canDeliverCommand(),
                        deliver: context.actions.deliverCommand
                    ),
                    preservesRenderedViews: sameMessage
                )
                stack.addArrangedSubview(markdownView)
            }
            if message.isStreaming, message.text.isEmpty {
                let activity = NativeActivityLabel(
                    text: String(localized: "Working…"),
                    alternatives: [
                        String(localized: "Working…"),
                        String(localized: "Thinking…"),
                        String(localized: "Reasoning…"),
                    ],
                    reduceMotion: context.configuration.reduceMotion,
                    measurement: context.measurement
                )
                activity.identifier = NSUserInterfaceItemIdentifier(
                    "Transcript.WorkingActivity"
                )
                stack.addArrangedSubview(activity)
            } else if !message.isStreaming {
                let actions = NativeStack.horizontal()
                actions.identifier = NSUserInterfaceItemIdentifier("Transcript.MessageActions")
                actions.addArrangedSubview(NativeCopyButton(text: message.text))
                if canFork {
                    let fork = NativeButton(
                        symbol: "arrow.triangle.branch",
                        help: String(localized: "Fork")
                    )
                    fork.handler = { context.actions.forkAssistantMessage(message.id) }
                    actions.addArrangedSubview(fork)
                }
                actions.addArrangedSubview(
                    NativeLabel(
                        ChatMessageTimestampFormatter.string(
                            for: message.createdAt,
                            locale: context.configuration.locale
                        ),
                        font: .monospacedDigitSystemFont(
                            ofSize: NSFont.smallSystemFontSize,
                            weight: .regular
                        ),
                        color: .tertiaryLabelColor
                    ))
                actions.addArrangedSubview(NativeFlexibleSpacer())
                context.registerHoverView(actions)
                stack.addArrangedSubview(actions)
            }
            for command in message.commands {
                stack.addArrangedSubview(commandCard(command, context: context))
            }
        }
    }

    static func update(
        _ view: NSView,
        for entry: TranscriptEntry,
        context: NativeTranscriptContext
    ) -> Bool {
        guard case .assistant(let message, let canFork) = entry.content,
            let view = view as? AssistantContent
        else { return false }
        view.configure(message: message, canFork: canFork, context: context)
        return true
    }

    static func view(for entry: TranscriptEntry, context: NativeTranscriptContext) -> NSView {
        switch entry.content {
        case .empty:
            return empty()
        case .interrupted:
            return labelRow(
                symbol: "pause.circle",
                text: String(localized: "This run was interrupted and was not resumed."),
                color: .secondaryLabelColor
            )
        case .user(let message, let canEdit):
            return user(message, canEdit: canEdit, context: context)
        case .assistant(let message, let canFork):
            return assistant(message, canFork: canFork, context: context)
        case .tool(let card):
            return tool(card, context: context)
        case .work(let group):
            return work(group, context: context)
        case .plan(let card):
            return plan(card, context: context)
        case .compaction(let mark):
            return compaction(mark)
        case .compactionActivity(let activity):
            return compactionActivity(activity, context: context)
        }
    }

    private static func empty() -> NSView {
        let stack = NativeStack.vertical(spacing: Metrics.Space.m)
        stack.edgeInsets = .init(
            top: Metrics.Space.xl, left: 0, bottom: Metrics.Space.xl, right: 0
        )
        stack.addArrangedSubview(
            NativeLabel(
                String(localized: "Start a Conversation"),
                font: .boldSystemFont(ofSize: NSFont.systemFontSize)
            ))
        stack.addArrangedSubview(
            NativeLabel(
                String(localized: "Ask a question or describe what you want to do."),
                color: .secondaryLabelColor
            ))
        return stack
    }

    private static func user(
        _ message: ChatMessage,
        canEdit: Bool,
        context: NativeTranscriptContext
    ) -> NSView {
        let outer = NativeStack.vertical(spacing: Metrics.Chat.blockSpacing)
        outer.alignment = .trailing
        let gutter =
            context.configuration.isCompact
            ? Metrics.Chat.compactGutter : Metrics.Chat.gutter
        if !message.images.isEmpty {
            let images = NativeFlowView(
                spacing: Metrics.Space.s,
                horizontalAlignment: .trailing
            )
            images.identifier = NSUserInterfaceItemIdentifier("Transcript.UserImages")
            for attachment in message.images {
                guard let image = NSImage(data: attachment.data) else { continue }
                let side =
                    context.configuration.isCompact
                    ? Metrics.Chat.compactImageTile : Metrics.Chat.imageTile
                let button = NativeImageTile(
                    image: image,
                    side: side,
                    label: attachment.label
                )
                button.handler = {
                    Task {
                        do { try await ContextAttachmentOpener.open(attachment) } catch {
                            context.presentError(
                                String(localized: "Couldn’t Open Attachment"),
                                error.localizedDescription
                            )
                        }
                    }
                }
                images.addItem(button)
            }
            if !images.isEmpty { outer.addArrangedSubview(images) }
        }
        if !message.contextChips.isEmpty {
            let chips = NativeFlowView(
                spacing: Metrics.Space.xs,
                horizontalAlignment: .trailing
            )
            chips.identifier = NSUserInterfaceItemIdentifier("Transcript.UserChips")
            for chip in message.contextChips {
                let button = NativeChipButton(symbol: chip.kind.symbol, title: chip.label)
                button.toolTip = String(localized: "Open \(chip.label)")
                button.handler = {
                    Task {
                        do {
                            if chip.kind == .image,
                                let image = message.images.first(where: { $0.id == chip.id })
                                    ?? message.images.first(where: { $0.label == chip.label })
                            {
                                try await ContextAttachmentOpener.open(image)
                            } else if let attachment = chip.attachment {
                                try await ContextAttachmentOpener.open(attachment)
                            }
                        } catch {
                            context.presentError(
                                String(localized: "Couldn’t Open Attachment"),
                                error.localizedDescription
                            )
                        }
                    }
                }
                chips.addItem(button)
            }
            outer.addArrangedSubview(chips)
        }
        if context.presentation.isEditingMessage(message.id) || !message.text.isEmpty {
            let bubbleLine = NSView()
            let bubble = NativeCard(radius: Metrics.Chat.bubbleRadius)
            bubble.identifier = NSUserInterfaceItemIdentifier("Transcript.UserBubble")
            bubble.fillProvider = {
                nativeHierarchicalColor(.controlAccentColor, opacity: 0.10)
            }
            bubble.onLayout = {
                guard !context.presentation.isEditingMessage(message.id), !context.measurement
                else { return }
                context.presentation.setMessageBubbleWidth(bubble.bounds.width, for: message.id)
            }
            let body = NativeStack.vertical(spacing: Metrics.Space.s)
            bubble.setContent(
                body,
                insets: .init(
                    top: Metrics.Space.m,
                    left: Metrics.Space.l,
                    bottom: Metrics.Space.m,
                    right: Metrics.Space.l
                )
            )
            if context.presentation.isEditingMessage(message.id) {
                body.addArrangedSubview(editor(message, context: context))
            } else {
                let markdown = NativeMarkdownView()
                markdown.identifier = NSUserInterfaceItemIdentifier("Transcript.UserMarkdown")
                markdown.configure(
                    package: context.markdownCache.package(
                        entryID: context.entryID,
                        slot: "user",
                        source: message.text,
                        shell: false
                    ),
                    measurement: context.measurement,
                    proposedWidth: max(
                        1,
                        context.contentWidth - gutter - Metrics.Space.l * 2
                    ),
                    fillsWidth: false,
                    actions: .init()
                )
                body.addArrangedSubview(markdown)
            }
            bubble.translatesAutoresizingMaskIntoConstraints = false
            bubbleLine.addSubview(bubble)
            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: bubbleLine.topAnchor),
                bubble.bottomAnchor.constraint(equalTo: bubbleLine.bottomAnchor),
                bubble.trailingAnchor.constraint(equalTo: bubbleLine.trailingAnchor),
                bubble.leadingAnchor.constraint(
                    greaterThanOrEqualTo: bubbleLine.leadingAnchor,
                    constant: gutter
                ),
                bubble.widthAnchor.constraint(
                    lessThanOrEqualTo: bubbleLine.widthAnchor,
                    constant: -gutter
                ),
            ])
            outer.addArrangedSubview(bubbleLine)
            bubbleLine.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        }

        let actions = NativeStack.horizontal()
        actions.identifier = NSUserInterfaceItemIdentifier("Transcript.MessageActions")
        actions.addArrangedSubview(NativeFlexibleSpacer())
        actions.addArrangedSubview(
            NativeLabel(
                ChatMessageTimestampFormatter.string(
                    for: message.createdAt,
                    locale: context.configuration.locale
                ),
                font: .monospacedDigitSystemFont(
                    ofSize: NSFont.smallSystemFontSize,
                    weight: .regular
                ),
                color: .tertiaryLabelColor
            ))
        if canEdit {
            let edit = NativeButton(symbol: "pencil", help: String(localized: "Edit"))
            edit.handler = {
                context.presentation.beginEditingMessage(message.id, text: message.text)
                context.invalidate(context.entryID, false)
            }
            actions.addArrangedSubview(edit)
        }
        actions.addArrangedSubview(NativeCopyButton(text: message.text))
        context.registerHoverView(actions)
        outer.addArrangedSubview(actions)
        actions.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        return outer
    }

    private static func editor(
        _ message: ChatMessage,
        context: NativeTranscriptContext
    ) -> NSView {
        let captured = context.presentation.messageBubbleWidth(message.id) - Metrics.Space.l * 2
        let editor = NativeMessageEditor(
            text: context.presentation.messageEditText(message.id),
            width: max(captured, context.configuration.isCompact ? 160 : 200),
            measurement: context.measurement
        )
        editor.onChange = { value in
            context.presentation.setMessageEditText(value, for: message.id)
            context.invalidate(context.entryID, false)
        }
        editor.onCancel = {
            context.presentation.endEditingMessage(message.id)
            context.invalidate(context.entryID, false)
        }
        editor.onCommit = { value in
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            context.presentation.endEditingMessage(message.id)
            context.actions.editUserMessage(message.id, value)
            context.invalidate(context.entryID, false)
        }
        return editor
    }

    private static func assistant(
        _ message: ChatMessage,
        canFork: Bool,
        context: NativeTranscriptContext
    ) -> NSView {
        let view = AssistantContent()
        view.configure(message: message, canFork: canFork, context: context)
        return view
    }

    private static func tool(_ card: AgentToolCard, context: NativeTranscriptContext) -> NSView {
        let stack = NativeStack.vertical()
        let expanded = context.presentation.isExpanded(card.id)
        let host = card.invocation.targetHostID.flatMap(context.actions.hostName)
        let title = AgentToolPresentation.summary(
            for: card,
            hostName: host,
            locale: context.configuration.locale
        )
        let header = NativeDisclosureHeader(
            symbol: AgentToolPresentation.symbol(for: card),
            title: title,
            iconColor: toolColor(card.state),
            titleColor: card.state == .running ? .secondaryLabelColor : .labelColor,
            expanded: expanded,
            active: card.state == .running,
            reviewing: card.state == .reviewing,
            reduceMotion: context.configuration.reduceMotion,
            measurement: context.measurement,
            lineLimit: expanded ? 0 : 1
        )
        header.alphaValue = card.state == .interrupted ? 0.5 : 1
        header.toolTip = expanded ? String(localized: "Hide details") : String(localized: "Show details")
        header.handler = {
            context.presentation.toggleDisclosure(card.id)
            context.invalidate(context.entryID, false)
        }
        stack.addArrangedSubview(header)
        if expanded {
            let detail = NativeStack.vertical()
            detail.edgeInsets = .init(
                top: 0,
                left: Metrics.Sidebar.rowIcon,
                bottom: 0,
                right: 0
            )
            if let review = card.review {
                detail.addArrangedSubview(
                    NativeLabel(
                        String(localized: "Security Review: \(review.risk.displayName) — \(review.reason)"),
                        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                        color: .secondaryLabelColor,
                        selectable: true
                    ))
            }
            if let projected = AgentToolPresentation.detail(
                for: card,
                locale: context.configuration.locale
            ) {
                for item in projected.items {
                    detail.addArrangedSubview(
                        toolDetail(item, isError: card.result?.isError == true)
                    )
                }
            }
            if card.result?.isTruncated == true {
                detail.addArrangedSubview(
                    NativeLabel(
                        String(localized: "Output truncated"),
                        font: .systemFont(ofSize: NSFont.smallSystemFontSize - 1),
                        color: .systemOrange
                    ))
            }
            stack.addArrangedSubview(detail)
        }
        return stack
    }

    private static func work(_ group: AgentWorkGroup, context: NativeTranscriptContext) -> NSView {
        let stack = NativeStack.vertical(spacing: Metrics.Space.m)
        let defaultExpanded = AgentWorkPresentation.isExpandedByDefault(
            for: group.run.state,
            appearsAfterAnswer: group.appearsAfterAnswer,
            isCompact: context.configuration.isCompact
        )
        let expanded = context.presentation.isExpanded(group.id, default: defaultExpanded)
        let titleProvider = {
            AgentWorkPresentation.title(
                for: group.run.state,
                from: group.run.startedAt,
                to: group.run.finishedAt ?? .now,
                locale: context.configuration.locale
            )
        }
        let header = NativeDisclosureHeader(
            symbol: nil,
            title: titleProvider(),
            titleColor: .secondaryLabelColor,
            expanded: expanded,
            reduceMotion: context.configuration.reduceMotion,
            measurement: context.measurement,
            lineLimit: 1,
            titleProvider: group.run.state.isTerminal ? nil : titleProvider
        )
        header.toolTip = expanded ? String(localized: "Hide work") : String(localized: "Show work")
        header.handler = {
            context.presentation.toggleDisclosure(group.id, default: defaultExpanded)
            context.invalidate(context.entryID, false)
        }
        stack.addArrangedSubview(header)
        if expanded {
            let workItems = NativeStack.vertical(spacing: Metrics.Chat.blockSpacing)
            for item in group.items {
                switch item {
                case .reasoning(let block):
                    let reasoning = markdown(
                        source: block.text,
                        slot: "reasoning.\(block.id)",
                        shell: false,
                        tone: .secondary,
                        context: context
                    )
                    reasoning.setScanning(
                        group.activeReasoningBlockID == block.id,
                        reduceMotion: context.configuration.reduceMotion,
                        measurement: context.measurement
                    )
                    workItems.addArrangedSubview(reasoning)
                case .message(let message):
                    if message.text.isEmpty, message.isStreaming {
                        workItems.addArrangedSubview(
                            NativeActivityLabel(
                                text: String(localized: "Working…"),
                                alternatives: [String(localized: "Working…")],
                                reduceMotion: context.configuration.reduceMotion,
                                measurement: context.measurement
                            ))
                    } else if !message.text.isEmpty {
                        workItems.addArrangedSubview(
                            markdown(
                                source: message.text,
                                slot: "work-message.\(message.id)",
                                shell: true,
                                context: context
                            ))
                    }
                case .tool(let card):
                    workItems.addArrangedSubview(tool(card, context: context))
                case .tools(let batch):
                    workItems.addArrangedSubview(toolBatch(batch, context: context))
                }
            }
            stack.addArrangedSubview(workItems)
        }
        let separator = NSBox()
        separator.boxType = .separator
        stack.addArrangedSubview(separator)
        return stack
    }

    private static func toolBatch(
        _ batch: AgentToolBatch,
        context: NativeTranscriptContext
    ) -> NSView {
        let stack = NativeStack.vertical(spacing: Metrics.Space.s)
        let expanded = context.presentation.isExpanded(batch.id)
        let unfinished = batch.cards.filter { !$0.state.isTerminal }
        let displayedReasoning: String? =
            if !unfinished.isEmpty,
                let reasoning = batch.reasoningTitle,
                AgentToolPresentation.showsReasoning(forBatchID: batch.id)
            {
                reasoning
            } else {
                nil
            }
        let title: String
        if unfinished.isEmpty {
            title = AgentToolPresentation.batchSummary(
                for: batch.cards,
                locale: context.configuration.locale
            )
        } else if let displayedReasoning {
            title = displayedReasoning
        } else {
            title = unfinished.map { card in
                AgentToolPresentation.summary(
                    for: card,
                    hostName: card.invocation.targetHostID.flatMap(context.actions.hostName),
                    locale: context.configuration.locale
                )
            }.joined(separator: "; ")
        }
        let header = NativeDisclosureHeader(
            symbol: AgentToolPresentation.batchSymbol(for: batch.cards),
            title: title,
            iconColor: batchColor(AgentToolPresentation.batchTint(for: batch.cards)),
            titleColor: .secondaryLabelColor,
            expanded: expanded,
            active: !unfinished.isEmpty,
            reduceMotion: context.configuration.reduceMotion,
            measurement: context.measurement,
            lineLimit: displayedReasoning == nil ? 0 : 1
        )
        header.toolTip = expanded ? String(localized: "Hide tools") : String(localized: "Show tools")
        header.handler = {
            context.presentation.toggleDisclosure(batch.id)
            context.invalidate(context.entryID, false)
        }
        stack.addArrangedSubview(header)
        if expanded {
            let cards = NativeStack.vertical(spacing: Metrics.Chat.blockSpacing)
            for card in batch.cards {
                cards.addArrangedSubview(tool(card, context: context))
            }
            stack.addArrangedSubview(cards)
        }
        return stack
    }

    private static func plan(_ card: AgentPlanCard, context: NativeTranscriptContext) -> NSView {
        let container = NativeCard(radius: Metrics.Radius.large)
        container.fillProvider = { NSColor.quaternaryLabelColor.withAlphaComponent(0.2) }
        container.strokeProvider = { NSColor.quaternaryLabelColor }
        let stack = NativeStack.vertical(spacing: Metrics.Space.s)
        stack.edgeInsets = .init(
            top: Metrics.Space.l,
            left: Metrics.Space.l,
            bottom: Metrics.Space.l,
            right: Metrics.Space.l
        )
        container.setContent(stack)
        let expanded = context.presentation.isExpanded(card.id)
        let symbol: String
        let tint: NSColor
        let outcome: String?
        switch card.outcome {
        case .pending:
            symbol = "lightbulb.max"
            tint = .controlAccentColor
            outcome = nil
        case .implemented:
            symbol = "checkmark.circle.fill"
            tint = .systemGreen
            outcome = String(localized: "Implemented")
        case .discarded:
            symbol = "xmark.circle"
            tint = .secondaryLabelColor
            outcome = String(localized: "Discarded")
        }
        let header = NativeDisclosureHeader(
            symbol: symbol,
            title: card.plan.title,
            iconColor: tint,
            titleColor: .labelColor,
            expanded: expanded,
            reduceMotion: context.configuration.reduceMotion,
            measurement: context.measurement,
            lineLimit: expanded ? 0 : 1,
            trailingText: outcome
        )
        header.toolTip = expanded ? String(localized: "Hide the plan") : String(localized: "Show the plan")
        header.handler = {
            context.presentation.toggleDisclosure(card.id)
            context.invalidate(context.entryID, false)
        }
        stack.addArrangedSubview(header)
        let body = markdown(
            source: card.plan.body,
            slot: "plan",
            shell: true,
            context: context
        )
        let indented = NativeStack.vertical()
        indented.edgeInsets = .init(
            top: 0,
            left: Metrics.Sidebar.rowIcon + Metrics.Space.s,
            bottom: 0,
            right: 0
        )
        let preview = NativePlanPreview(content: body, expanded: expanded)
        preview.handler = {
            guard !expanded else { return }
            context.presentation.toggleDisclosure(card.id)
            context.invalidate(context.entryID, false)
        }
        indented.addArrangedSubview(preview)
        stack.addArrangedSubview(indented)
        if card.outcome == .pending {
            let actions = NativeStack.horizontal()
            let discard = NativeButton(title: String(localized: "Discard"))
            discard.contentTintColor = .systemRed
            discard.handler = { context.actions.resolvePlan(card.id, .discarded) }
            let implement = NativeButton(
                title: String(localized: "Implement"),
                bordered: true,
                prominent: true
            )
            implement.isEnabled = !context.configuration.isConversationStreaming
            implement.handler = { context.actions.implementPlan(card) }
            actions.addArrangedSubview(discard)
            actions.addArrangedSubview(NativeFlexibleSpacer())
            actions.addArrangedSubview(
                NativeLabel(
                    String(localized: "Reply to keep planning"),
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    color: .secondaryLabelColor
                ))
            actions.addArrangedSubview(implement)
            stack.addArrangedSubview(actions)
        }
        return container
    }

    private static func compaction(_ mark: AgentCompactionMark) -> NSView {
        let row = NativeStack.horizontal(spacing: Metrics.Space.s)
        row.addArrangedSubview(NativeRule())
        row.addArrangedSubview(
            labelRow(
                symbol: "doc.text",
                text: String(
                    localized:
                        "Compacted — \(ContextBreakdownView.compact(mark.summarizedTokens)) summarized to \(ContextBreakdownView.compact(mark.keptTokens))"
                ),
                color: .secondaryLabelColor
            ))
        row.addArrangedSubview(NativeRule())
        row.toolTip = String(
            localized: "Earlier turns are summarized for the model. Nothing was deleted."
        )
        return row
    }

    private static func compactionActivity(
        _ activity: AgentCompactionActivity,
        context: NativeTranscriptContext
    ) -> NSView {
        let stack = NativeStack.vertical()
        let failure: String? = if case .failed(let reason) = activity.state { reason } else { nil }
        let title =
            failure == nil
            ? String(localized: "Compacting context")
            : String(localized: "Couldn’t compact context")
        let expanded = context.presentation.isExpanded(activity.id)
        let header = NativeDisclosureHeader(
            symbol: failure == nil ? "doc.text.magnifyingglass" : "exclamationmark.triangle",
            title: title,
            iconColor: failure == nil ? .secondaryLabelColor : .systemRed,
            titleColor: failure == nil ? .secondaryLabelColor : .labelColor,
            expanded: failure == nil ? nil : expanded,
            active: failure == nil,
            reduceMotion: context.configuration.reduceMotion,
            measurement: context.measurement,
            lineLimit: 1
        )
        header.toolTip =
            failure == nil
            ? String(localized: "Compacting context")
            : String(localized: "Show failure details")
        header.handler = {
            guard failure != nil else { return }
            context.presentation.toggleDisclosure(activity.id)
            context.invalidate(context.entryID, false)
        }
        stack.addArrangedSubview(header)
        if let failure, expanded {
            let detail = NativeStack.horizontal(spacing: Metrics.Space.m)
            detail.edgeInsets = .init(
                top: 0,
                left: Metrics.Sidebar.rowIcon,
                bottom: 0,
                right: 0
            )
            detail.addArrangedSubview(NativeVerticalRule())
            detail.addArrangedSubview(
                NativeLabel(
                    failure,
                    font: .monospacedSystemFont(
                        ofSize: NSFont.smallSystemFontSize,
                        weight: .regular
                    ),
                    color: .systemRed,
                    selectable: true
                ))
            stack.addArrangedSubview(detail)
        }
        return stack
    }

    private static func markdown(
        source: String,
        slot: String,
        shell: Bool,
        tone: TermindMarkdownView.Tone = .primary,
        fillsWidth: Bool = true,
        context: NativeTranscriptContext
    ) -> NativeMarkdownView {
        let view = NativeMarkdownView()
        view.configure(
            package: context.markdownCache.package(
                entryID: context.entryID,
                slot: slot,
                source: source,
                shell: shell,
                tone: tone
            ),
            measurement: context.measurement,
            proposedWidth: context.contentWidth,
            fillsWidth: fillsWidth,
            actions: .init(
                enabled: context.configuration.showsTerminalActions
                    && context.actions.canDeliverCommand(),
                deliver: context.actions.deliverCommand
            )
        )
        return view
    }

    private static func labelRow(symbol: String, text: String, color: NSColor) -> NSView {
        let row = NativeStack.horizontal()
        let image = NSImageView(
            image: NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: nil
            ) ?? NSImage())
        image.contentTintColor = color
        row.addArrangedSubview(image)
        row.addArrangedSubview(NativeLabel(text, color: color))
        return row
    }

    private static func commandCard(
        _ command: SuggestedCommand,
        context: NativeTranscriptContext
    ) -> NSView {
        let assessment = command.risk
        let card = NativeCard(radius: Metrics.Radius.medium)
        card.fillProvider = { NSColor.quaternaryLabelColor.withAlphaComponent(0.2) }
        if assessment.risk == .destructive {
            card.strokeProvider = { NSColor.systemRed.withAlphaComponent(0.4) }
        }
        let stack = NativeStack.vertical()
        stack.edgeInsets = .init(
            top: Metrics.Space.l,
            left: Metrics.Space.l,
            bottom: Metrics.Space.l,
            right: Metrics.Space.l
        )
        card.setContent(stack)
        let header = NativeStack.horizontal(spacing: Metrics.Space.xs)
        header.addArrangedSubview(
            labelRow(
                symbol: "sparkles",
                text: String(localized: "Suggested Command"),
                color: .secondaryLabelColor
            ))
        header.addArrangedSubview(NativeFlexibleSpacer())
        header.addArrangedSubview(NativeRiskBadge(assessment: assessment))
        stack.addArrangedSubview(header)

        let commandBackground = NativeCard(radius: Metrics.Radius.small)
        commandBackground.fillProvider = {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.4)
        }
        let commandLabel = NativeLabel(
            command.command,
            font: .monospacedSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            ),
            selectable: true
        )
        let commandInsets = NativeStack.vertical()
        commandInsets.edgeInsets = .init(
            top: Metrics.Space.m,
            left: Metrics.Space.m,
            bottom: Metrics.Space.m,
            right: Metrics.Space.m
        )
        commandInsets.addArrangedSubview(commandLabel)
        commandBackground.setContent(commandInsets)
        stack.addArrangedSubview(commandBackground)
        if !command.explanation.isEmpty {
            stack.addArrangedSubview(
                NativeLabel(
                    command.explanation,
                    color: .secondaryLabelColor
                ))
        }
        for reason in assessment.reasons {
            stack.addArrangedSubview(
                NativeLabel(
                    "• \(reason)",
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    color: riskColor(assessment.risk)
                ))
        }
        let actions = NativeStack.horizontal()
        if context.configuration.showsTerminalActions {
            let insert = NativeButton(title: String(localized: "Insert"))
            insert.isEnabled = context.actions.canDeliverCommand()
            insert.handler = { context.actions.deliverCommand(command.command, false) }
            let run = NativeButton(
                title: String(localized: "Run"),
                bordered: true,
                prominent: true
            )
            run.isEnabled = context.actions.canDeliverCommand()
            run.bezelColor = assessment.risk == .destructive ? .systemRed : .controlAccentColor
            run.handler = { [weak run] in
                let deliver = { context.actions.deliverCommand(command.command, true) }
                if assessment.requiresSecondConfirmation {
                    confirmDestructiveCommand(
                        command.command,
                        reasons: assessment.reasons,
                        from: run,
                        action: deliver
                    )
                } else {
                    deliver()
                }
            }
            actions.addArrangedSubview(insert)
            actions.addArrangedSubview(run)
        }
        actions.addArrangedSubview(NativeFlexibleSpacer())
        actions.addArrangedSubview(NativeCopyButton(text: command.command))
        stack.addArrangedSubview(actions)
        return card
    }

    private static func toolDetail(_ item: AgentToolDetail.Item, isError: Bool) -> NSView {
        switch item {
        case .field(let field):
            let row = NativeStack.horizontal(spacing: Metrics.Space.s)
            let key = NativeLabel(
                field.label,
                font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                color: .secondaryLabelColor
            )
            key.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
            row.addArrangedSubview(key)
            let font: NSFont =
                field.isMonospaced
                ? .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
                : .systemFont(ofSize: NSFont.smallSystemFontSize)
            if let raw = field.url, let url = URL(string: raw) {
                let link = NativeButton(title: field.value)
                link.font = font
                link.contentTintColor = .linkColor
                link.handler = { NSWorkspace.shared.open(url) }
                row.addArrangedSubview(link)
            } else {
                row.addArrangedSubview(
                    NativeLabel(
                        field.value,
                        font: font,
                        color: isError ? .systemRed : .labelColor,
                        selectable: true
                    ))
            }
            return row
        case .message(let text, let tint):
            return NativeLabel(
                text,
                font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                color: detailColor(tint),
                selectable: true
            )
        case .text(let block):
            let stack = NativeStack.vertical(spacing: Metrics.Space.xs)
            if let title = block.title {
                stack.addArrangedSubview(
                    NativeLabel(
                        title,
                        font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                        color: .secondaryLabelColor
                    ))
            }
            let preview = AgentToolPresentation.preview(block.text)
            stack.addArrangedSubview(
                NativeLabel(
                    preview.displayed,
                    font: block.style == .monospaced
                        ? .monospacedSystemFont(
                            ofSize: NSFont.smallSystemFontSize,
                            weight: .regular
                        ) : .systemFont(ofSize: NSFont.smallSystemFontSize),
                    color: isError ? .systemRed : .secondaryLabelColor,
                    selectable: true
                ))
            if preview.isShortened {
                let actions = NativeStack.horizontal(spacing: Metrics.Space.s)
                actions.addArrangedSubview(
                    NativeLabel(
                        String(localized: "Output shortened for display"),
                        font: .systemFont(ofSize: NSFont.smallSystemFontSize - 1),
                        color: .secondaryLabelColor
                    ))
                actions.addArrangedSubview(NativeCopyButton(text: preview.full))
                stack.addArrangedSubview(actions)
            }
            return stack
        case .list(let list):
            let stack = NativeStack.vertical()
            if let title = list.title {
                stack.addArrangedSubview(
                    NativeLabel(
                        title,
                        font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                        color: .secondaryLabelColor
                    ))
            }
            if list.rows.isEmpty, let empty = list.emptyMessage {
                stack.addArrangedSubview(
                    NativeLabel(
                        empty,
                        font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                        color: .secondaryLabelColor
                    ))
            } else {
                for row in list.rows { stack.addArrangedSubview(toolListRow(row)) }
            }
            return stack
        case .groupedList(let list):
            let stack = NativeStack.vertical()
            stack.addArrangedSubview(
                NativeLabel(
                    list.summary,
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
                    color: .secondaryLabelColor
                ))
            for section in list.sections {
                stack.addArrangedSubview(
                    NativeLabel(
                        section.title,
                        font: .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
                    ))
                for row in section.rows { stack.addArrangedSubview(toolListRow(row)) }
            }
            return stack
        }
    }

    private static func toolListRow(_ row: AgentToolDetail.ListRow) -> NSView {
        let outer = NativeStack.horizontal(spacing: Metrics.Space.s)
        if let symbol = row.symbol {
            let icon = NSImageView(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
            )
            icon.contentTintColor = detailColor(row.tint)
            icon.widthAnchor.constraint(equalToConstant: Metrics.Sidebar.rowIcon).isActive = true
            outer.addArrangedSubview(icon)
        }
        let body = NativeStack.vertical(spacing: Metrics.Space.xxs)
        if let raw = row.url, let url = URL(string: raw) {
            let link = NativeButton(title: row.title)
            link.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            link.contentTintColor = .linkColor
            link.handler = { NSWorkspace.shared.open(url) }
            body.addArrangedSubview(link)
        } else {
            body.addArrangedSubview(
                NativeLabel(
                    row.title,
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
                ))
        }
        if let subtitle = row.subtitle, !subtitle.isEmpty {
            body.addArrangedSubview(
                NativeLabel(
                    subtitle,
                    font: .monospacedSystemFont(
                        ofSize: NSFont.smallSystemFontSize,
                        weight: .regular
                    ),
                    color: .secondaryLabelColor,
                    selectable: true
                ))
        }
        if let detail = row.detail, !detail.isEmpty {
            body.addArrangedSubview(
                NativeLabel(
                    detail,
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize - 1),
                    color: .secondaryLabelColor,
                    selectable: true
                ))
        }
        if !row.badges.isEmpty {
            let badges = NativeFlowView(spacing: Metrics.Space.xs)
            for badge in row.badges { badges.addItem(NativeBadge(text: badge)) }
            body.addArrangedSubview(badges)
        }
        outer.addArrangedSubview(body)
        return outer
    }

    private static func toolColor(_ state: AgentToolCard.State) -> NSColor {
        switch state {
        case .denied, .failed: .systemRed
        case .reviewing, .waitingForApproval, .waitingForUser: .systemOrange
        case .completed: .systemGreen
        default: .secondaryLabelColor
        }
    }

    private static func batchColor(_ tint: AgentToolPresentation.BatchTint) -> NSColor {
        switch tint {
        case .secondary: .secondaryLabelColor
        case .warning: .systemOrange
        case .success: .systemGreen
        case .failure: .systemRed
        }
    }

    private static func detailColor(_ tint: AgentToolDetail.Tint) -> NSColor {
        switch tint {
        case .secondary: .secondaryLabelColor
        case .warning: .systemOrange
        case .success: .systemGreen
        case .failure: .systemRed
        }
    }

    private static func riskColor(_ risk: CommandRisk) -> NSColor {
        switch risk {
        case .safe: .systemGreen
        case .caution: .systemOrange
        case .destructive: .systemRed
        }
    }

    private static func confirmDestructiveCommand(
        _ command: String,
        reasons: [String],
        from view: NSView?,
        action: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "Run a destructive command?")
        alert.informativeText = reasons.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Run \(command)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if let window = view?.window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { action() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }
}

@MainActor
private func nativeRiskColor(_ risk: CommandRisk) -> NSColor {
    switch risk {
    case .safe: .systemGreen
    case .caution: .systemOrange
    case .destructive: .systemRed
    }
}

@MainActor
private func nativeHierarchicalColor(_ color: NSColor, opacity: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved.withAlphaComponent(resolved.alphaComponent * opacity)
    }
}

@MainActor
private func presentDestructiveCommandConfirmation(
    _ command: String,
    reasons: [String],
    from view: NSView?,
    action: @escaping () -> Void
) {
    let alert = NSAlert()
    alert.alertStyle = .critical
    alert.messageText = String(localized: "Run a destructive command?")
    alert.informativeText = reasons.joined(separator: "\n")
    alert.addButton(withTitle: String(localized: "Run \(command)"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    if let window = view?.window {
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    } else if alert.runModal() == .alertFirstButtonReturn {
        action()
    }
}

@MainActor
private final class NativeMarkdownView: NSView {
    struct Actions {
        var enabled = false
        var deliver: (String, Bool) -> Void = { _, _ in }
    }

    private let stack = NativeStack.vertical(spacing: Metrics.Chat.blockSpacing)
    private var segmentViews: [NSView] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(
        package: TranscriptMarkdownCache.Package,
        measurement: Bool,
        proposedWidth: CGFloat,
        fillsWidth: Bool,
        actions: Actions,
        preservesRenderedViews: Bool = false
    ) {
        if preservesRenderedViews,
            segmentViews.count == package.rendered.segments.count,
            zip(package.rendered.segments, segmentViews).allSatisfy({ segment, view in
                switch (segment.content, view) {
                case (.markdown, is NativeMarkdownSegment): true
                default: false
                }
            })
        {
            for (segment, view) in zip(package.rendered.segments, segmentViews) {
                guard case .markdown(let content) = segment.content,
                    let view = view as? NativeMarkdownSegment
                else { continue }
                view.configure(
                    content: content,
                    theme: package.rendered.theme,
                    proposedWidth: proposedWidth,
                    fillsWidth: fillsWidth,
                    immediate: measurement
                )
            }
            invalidateIntrinsicContentSize()
            return
        }
        stack.removeAllArrangedSubviews()
        segmentViews.removeAll()
        for segment in package.rendered.segments {
            switch segment.content {
            case .markdown(let content):
                let view = NativeMarkdownSegment()
                view.configure(
                    content: content,
                    theme: package.rendered.theme,
                    proposedWidth: proposedWidth,
                    fillsWidth: fillsWidth,
                    immediate: true
                )
                stack.addArrangedSubview(view)
                segmentViews.append(view)
            case .shell(let language, let command):
                let view = shell(language: language, command: command, actions: actions)
                stack.addArrangedSubview(view)
                segmentViews.append(view)
            }
        }
        invalidateIntrinsicContentSize()
    }

    func setScanning(_ active: Bool, reduceMotion: Bool, measurement: Bool) {
        guard active, !reduceMotion, !measurement else {
            layer?.mask = nil
            return
        }
        wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.white.cgColor,
        ]
        gradient.locations = [0, 0.5, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = gradient
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -96
        animation.toValue = 192
        animation.duration = 1.55
        animation.repeatCount = .infinity
        gradient.add(animation, forKey: "scan")
    }

    override func layout() {
        super.layout()
        layer?.mask?.frame = bounds.insetBy(dx: -48, dy: 0)
    }

    override var intrinsicContentSize: NSSize {
        let size = stack.fittingSize
        return NSSize(width: max(1, size.width), height: max(1, size.height))
    }

    private func shell(language: String, command: String, actions: Actions) -> NSView {
        let assessment = CommandRiskClassifier.assess(command)
        let card = NativeCard(radius: Metrics.Radius.medium)
        card.fillProvider = { NSColor.quaternaryLabelColor.withAlphaComponent(0.3) }
        if assessment.risk == .destructive {
            card.strokeProvider = { NSColor.systemRed.withAlphaComponent(0.4) }
        }
        let stack = NativeStack.vertical()
        stack.edgeInsets = .init(
            top: Metrics.Chat.codeInset,
            left: Metrics.Chat.codeInset,
            bottom: Metrics.Chat.codeInset,
            right: Metrics.Chat.codeInset
        )
        card.setContent(stack)
        let header = NativeStack.horizontal(spacing: Metrics.Space.xs)
        header.addArrangedSubview(
            NativeLabel(
                language,
                font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                color: .secondaryLabelColor
            ))
        header.addArrangedSubview(NativeFlexibleSpacer())
        header.addArrangedSubview(NativeRiskBadge(assessment: assessment))
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(
            NativeLabel(
                command,
                font: .monospacedSystemFont(
                    ofSize: NSFont.systemFontSize,
                    weight: .regular
                ),
                selectable: true
            ))
        for reason in assessment.reasons {
            stack.addArrangedSubview(
                NativeLabel(
                    "• \(reason)",
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    color: nativeRiskColor(assessment.risk)
                ))
        }
        let row = NativeStack.horizontal()
        if !command.contains("\n") {
            let insert = NativeButton(title: String(localized: "Insert"))
            insert.isEnabled = actions.enabled
            insert.handler = { actions.deliver(command, false) }
            let run = NativeButton(
                title: String(localized: "Run"),
                bordered: true,
                prominent: true
            )
            run.isEnabled = actions.enabled
            run.bezelColor = assessment.risk == .destructive ? .systemRed : .controlAccentColor
            run.handler = { [weak run] in
                let deliver = { actions.deliver(command, true) }
                if assessment.requiresSecondConfirmation {
                    presentDestructiveCommandConfirmation(
                        command,
                        reasons: assessment.reasons,
                        from: run,
                        action: deliver
                    )
                } else {
                    deliver()
                }
            }
            row.addArrangedSubview(insert)
            row.addArrangedSubview(run)
        } else {
            row.addArrangedSubview(
                NativeLabel(
                    String(localized: "Several commands — copy and review before running."),
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    color: .secondaryLabelColor
                ))
        }
        row.addArrangedSubview(NativeFlexibleSpacer())
        row.addArrangedSubview(NativeCopyButton(text: command))
        stack.addArrangedSubview(row)
        return card
    }
}

@MainActor
private final class NativeMarkdownSegment: NSView {
    private let markdown = MarkdownTextView()
    private var content: MarkdownContent?
    private var measuredSize = NSSize(width: 1, height: 1)
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(markdown)
        markdown.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            markdown.leadingAnchor.constraint(equalTo: leadingAnchor),
            markdown.trailingAnchor.constraint(equalTo: trailingAnchor),
            markdown.topAnchor.constraint(equalTo: topAnchor),
            markdown.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        heightConstraint = heightAnchor.constraint(equalToConstant: 1)
        heightConstraint.priority = NSLayoutConstraint.Priority(rawValue: 999)
        heightConstraint.isActive = true
        markdown.linkHandler = { payload, _, _ in
            let url: URL? =
                switch payload {
                case .url(let url): url
                case .string(let value): URL(string: value)
                }
            if let url,
                TermindMarkdownParser.allowedLinkSchemes.contains(
                    url.scheme?.lowercased() ?? ""
                )
            {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(
        content: MarkdownContent,
        theme: MarkdownTheme,
        proposedWidth: CGFloat,
        fillsWidth: Bool,
        immediate: Bool
    ) {
        guard self.content !== content else { return }
        let hadContent = self.content != nil
        self.content = content
        let availableWidth = max(1, proposedWidth)
        frame.size.width = availableWidth
        markdown.frame.size.width = availableWidth
        if immediate || !hadContent {
            markdown.setContentImmediately(content, theme: theme)
        } else {
            markdown.theme = theme
            markdown.setContent(content)
        }
        let bounded = markdown.boundingSize(for: availableWidth)
        let measuredWidth =
            fillsWidth
            ? availableWidth
            : min(availableWidth, max(1, ceil(bounded.width)))
        let measuredHeight = max(1, ceil(markdown.boundingSize(for: measuredWidth).height))
        measuredSize = NSSize(width: measuredWidth, height: measuredHeight)
        heightConstraint.constant = measuredHeight
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        measuredSize
    }
}

@MainActor
private final class NativeFlowView: NSView {
    enum HorizontalAlignment {
        case leading
        case trailing
    }

    private let spacing: CGFloat
    private let horizontalAlignment: HorizontalAlignment
    private var items: [NSView] = []
    private var lastWidth: CGFloat = 0
    var isEmpty: Bool { items.isEmpty }

    init(
        spacing: CGFloat,
        horizontalAlignment: HorizontalAlignment = .leading
    ) {
        self.spacing = spacing
        self.horizontalAlignment = horizontalAlignment
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func addItem(_ view: NSView) {
        items.append(view)
        addSubview(view)
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        let available = max(1, bounds.width)
        var y: CGFloat = 0
        for row in rows(for: available) {
            let rowWidth = row.reduce(CGFloat.zero) { $0 + $1.size.width }
                + spacing * CGFloat(max(0, row.count - 1))
            var x: CGFloat =
                horizontalAlignment == .trailing ? max(0, available - rowWidth) : 0
            let rowHeight = row.map(\.size.height).max() ?? 0
            for item in row {
                item.view.frame = CGRect(
                    x: x,
                    y: y,
                    width: min(item.size.width, available),
                    height: item.size.height
                )
                x += item.size.width + spacing
            }
            y += rowHeight + spacing
        }
        if abs(lastWidth - available) > 0.5 {
            lastWidth = available
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let available = max(1, bounds.width > 0 ? bounds.width : superview?.bounds.width ?? 1)
        let rows = rows(for: available)
        let height = rows.reduce(CGFloat.zero) { total, row in
            total + (row.map(\.size.height).max() ?? 0)
        }
            + spacing * CGFloat(max(0, rows.count - 1))
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    private struct Item {
        let view: NSView
        let size: NSSize
    }

    private func rows(for available: CGFloat) -> [[Item]] {
        var result: [[Item]] = []
        var row: [Item] = []
        var rowWidth: CGFloat = 0
        for view in items {
            let item = Item(view: view, size: view.fittingSize)
            let nextWidth = rowWidth + (row.isEmpty ? 0 : spacing) + item.size.width
            if !row.isEmpty, nextWidth > available {
                result.append(row)
                row = []
                rowWidth = 0
            }
            rowWidth += (row.isEmpty ? 0 : spacing) + item.size.width
            row.append(item)
        }
        if !row.isEmpty { result.append(row) }
        return result
    }
}

@MainActor
private final class NativeDisclosureHeader: NSControl {
    var handler: (() -> Void)?
    private let row = NativeStack.horizontal(spacing: Metrics.Space.s)
    private var titleLabel: NativeLabel!
    private var timer: Timer?
    private var titleProvider: (() -> String)?

    init(
        symbol: String?,
        title: String,
        iconColor: NSColor = .secondaryLabelColor,
        titleColor: NSColor = .labelColor,
        expanded: Bool? = nil,
        active: Bool = false,
        reviewing: Bool = false,
        reduceMotion: Bool = false,
        measurement: Bool = false,
        lineLimit: Int = 1,
        titleProvider: (() -> String)? = nil,
        trailingText: String? = nil
    ) {
        super.init(frame: .zero)
        if let symbol {
            let icon = NSImageView(
                image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
            )
            icon.contentTintColor = iconColor
            icon.widthAnchor.constraint(equalToConstant: Metrics.Sidebar.rowIcon).isActive = true
            row.addArrangedSubview(icon)
        }
        if active {
            titleLabel = NativeActivityLabel(
                text: title,
                alternatives: [title],
                color: titleColor,
                reduceMotion: reduceMotion,
                measurement: measurement
            )
        } else {
            titleLabel = NativeLabel(title, color: titleColor)
        }
        titleLabel.maximumNumberOfLines = lineLimit
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(NativeFlexibleSpacer())
        if let trailingText {
            row.addArrangedSubview(
                NativeLabel(
                    trailingText,
                    font: .systemFont(ofSize: NSFont.smallSystemFontSize),
                    color: .secondaryLabelColor
                ))
        }
        if let expanded {
            let chevron = NSImageView(
                image: NSImage(
                    systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                    accessibilityDescription: nil
                ) ?? NSImage()
            )
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.symbolConfiguration = .init(pointSize: 8, weight: .bold)
            row.addArrangedSubview(chevron)
        }
        if reviewing {
            let shield = NSImageView(
                image: NSImage(
                    systemSymbolName: "checkmark.shield",
                    accessibilityDescription: String(localized: "Security Review in progress")
                ) ?? NSImage()
            )
            shield.contentTintColor = .systemOrange
            row.addArrangedSubview(shield)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityLabel(title)
        if let titleProvider, !measurement {
            self.titleProvider = titleProvider
            timer = Timer.scheduledTimer(
                timeInterval: 1,
                target: self,
                selector: #selector(refreshTitle),
                userInfo: nil,
                repeats: true
            )
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { timer?.invalidate() }
    }

    @objc private func refreshTitle() {
        guard let titleProvider else { return }
        titleLabel.stringValue = titleProvider()
    }

    override func mouseDown(with event: NSEvent) {
        if isEnabled { handler?() }
    }
}

@MainActor
private final class NativePlanPreview: NSControl {
    var handler: (() -> Void)?
    private let content: NSView
    private let expanded: Bool

    init(content: NSView, expanded: Bool) {
        self.content = content
        self.expanded = expanded
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
        ])
        if expanded {
            content.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        } else {
            heightAnchor.constraint(lessThanOrEqualToConstant: Metrics.Chat.planPreviewHeight).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard !expanded else {
            layer?.mask = nil
            return
        }
        let mask = CAGradientLayer()
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        mask.locations = [0, 0.72, 1]
        mask.startPoint = CGPoint(x: 0.5, y: 0)
        mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.frame = bounds
        layer?.mask = mask
    }

    override func mouseDown(with event: NSEvent) {
        if !expanded { handler?() }
    }

    override var intrinsicContentSize: NSSize {
        let size = content.fittingSize
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: expanded ? size.height : min(size.height, Metrics.Chat.planPreviewHeight)
        )
    }
}

@MainActor
private final class NativeChipButton: NativeButton {
    init(symbol: String, title: String) {
        super.init()
        identifier = NSUserInterfaceItemIdentifier("Transcript.UserChip")
        let content = NativeStack.horizontal(spacing: Metrics.Space.xs)
        content.identifier = NSUserInterfaceItemIdentifier("Transcript.UserChipContent")
        let icon = NSImageView(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage()
        )
        icon.contentTintColor = .labelColor
        icon.symbolConfiguration = .init(
            pointSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
        ])
        content.addArrangedSubview(icon)
        let label = NativeLabel(
            title,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize)
        )
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        content.addArrangedSubview(label)
        addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.Space.s),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.Space.s),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        wantsLayer = true
        layer?.cornerRadius = 10
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = true
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = nativeHierarchicalColor(
            .quaternaryLabelColor,
            opacity: 0.5
        ).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let size = subviews.first?.fittingSize ?? NSSize(width: 0, height: 0)
        return NSSize(
            width: size.width + Metrics.Space.s * 2,
            height: max(20, size.height + 6)
        )
    }
}

@MainActor
private final class NativeRiskBadge: NSView {
    private let assessment: RiskAssessment
    private let label: NativeLabel

    init(assessment: RiskAssessment) {
        self.assessment = assessment
        label = NativeLabel(
            assessment.risk.label,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium),
            color: Self.color(assessment.risk)
        )
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        toolTip = assessment.reasons.first ?? assessment.risk.label
        let row = NativeStack.horizontal(spacing: Metrics.Space.xs)
        let image = NSImageView(
            image: NSImage(
                systemSymbolName: assessment.risk.symbol,
                accessibilityDescription: assessment.risk.label
            ) ?? NSImage()
        )
        image.contentTintColor = Self.color(assessment.risk)
        row.addArrangedSubview(image)
        row.addArrangedSubview(label)
        row.edgeInsets = .init(top: 2, left: Metrics.Space.s, bottom: 2, right: Metrics.Space.s)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = Self.color(assessment.risk).withAlphaComponent(0.12).cgColor
    }

    private static func color(_ risk: CommandRisk) -> NSColor {
        switch risk {
        case .safe: .systemGreen
        case .caution: .systemOrange
        case .destructive: .systemRed
        }
    }
}

@MainActor
private final class NativeBadge: NSView {
    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        let label = NativeLabel(
            text,
            font: .systemFont(ofSize: NSFont.smallSystemFontSize - 1),
            color: .secondaryLabelColor
        )
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.Space.xs),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.Space.xs),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.5).cgColor
    }
}

@MainActor
private final class NativeImageTile: NativeButton {
    private let tileSide: CGFloat
    private let preview = NSView()

    init(image: NSImage, side: CGFloat, label: String) {
        tileSide = side
        super.init()
        identifier = NSUserInterfaceItemIdentifier("Transcript.UserImage")
        toolTip = String(localized: "Open \(label)")
        setAccessibilityLabel(label)
        preview.identifier = NSUserInterfaceItemIdentifier("Transcript.UserImagePreview")
        preview.wantsLayer = true
        preview.layer?.contents = image
        preview.layer?.contentsGravity = .resizeAspectFill
        preview.layer?.masksToBounds = true
        preview.layer?.cornerRadius = Metrics.Radius.medium
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor),
            preview.topAnchor.constraint(equalTo: topAnchor),
            preview.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: tileSide, height: tileSide)
    }
}

@MainActor
private final class NativeFlexibleSpacer: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 0, height: NSView.noIntrinsicMetric)
    }
}

@MainActor
private final class NativeRule: NSBox {
    override init(frame: NSRect) {
        super.init(frame: frame)
        boxType = .separator
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class NativeVerticalRule: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Metrics.Chat.rule / 2
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        widthAnchor.constraint(equalToConstant: Metrics.Chat.rule).isActive = true
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class NativeEditorTextView: NSTextView {
    var commit: (() -> Void)?
    var cancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let disallowed: NSEvent.ModifierFlags = [.control, .option]
            if !hasMarkedText(), !modifiers.contains(.shift), modifiers.intersection(disallowed).isEmpty {
                commit?()
                return
            }
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class NativeMessageEditor: NSView, NSTextViewDelegate {
    var onChange: (String) -> Void = { _ in }
    var onCommit: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}

    private let stack = NativeStack.vertical(spacing: Metrics.Space.s)
    private let scroll = NSScrollView()
    private let textView = NativeEditorTextView()
    private var heightConstraint: NSLayoutConstraint!
    private let editorWidth: CGFloat
    private let isMeasurement: Bool

    init(text: String, width: CGFloat, measurement: Bool) {
        editorWidth = width
        isMeasurement = measurement
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("Transcript.UserEditor")
        scroll.identifier = NSUserInterfaceItemIdentifier("Transcript.UserEditorScroll")
        textView.identifier = NSUserInterfaceItemIdentifier("Transcript.UserEditorText")
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
        ])

        textView.isRichText = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.string = text
        textView.delegate = self
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: max(1, width - 8),
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.commit = { [weak self] in
            guard let self else { return }
            onCommit(textView.string)
        }
        textView.cancel = { [weak self] in self?.onCancel() }
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        heightConstraint = scroll.heightAnchor.constraint(
            equalToConstant: Self.height(for: text, width: width)
        )
        heightConstraint.isActive = true
        stack.addArrangedSubview(scroll)

        let actions = NativeStack.horizontal(spacing: Metrics.Space.s)
        actions.addArrangedSubview(NativeFlexibleSpacer())
        let cancel = NativeButton(title: String(localized: "Cancel"))
        cancel.contentTintColor = .secondaryLabelColor
        cancel.handler = { [weak self] in self?.onCancel() }
        let send = NativeButton(title: String(localized: "Send"), bordered: true, prominent: true)
        send.handler = { [weak self] in
            guard let self else { return }
            onCommit(textView.string)
        }
        actions.addArrangedSubview(cancel)
        actions.addArrangedSubview(send)
        stack.addArrangedSubview(actions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !isMeasurement, let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            window.makeFirstResponder(textView)
        }
    }

    func textDidChange(_ notification: Notification) {
        heightConstraint.constant = Self.height(for: textView.string, width: editorWidth)
        textView.invalidateIntrinsicContentSize()
        onChange(textView.string)
    }

    private static func height(for text: String, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: max(1, width - 12), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
        return min(160, max(44, ceil(rect.height) + 16))
    }
}

@MainActor
private final class NativeActivityLabel: NativeLabel {
    private let alternatives: [String]
    private var timer: Timer?
    private var index = 0

    init(
        text: String,
        alternatives: [String],
        color: NSColor = .secondaryLabelColor,
        reduceMotion: Bool,
        measurement: Bool
    ) {
        self.alternatives = alternatives
        super.init(text, color: color)
        guard !measurement, !reduceMotion, alternatives.count > 1 else { return }
        timer = Timer.scheduledTimer(
            timeInterval: 2.8,
            target: self,
            selector: #selector(advanceText),
            userInfo: nil,
            repeats: true
        )
        installScanAnimation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { timer?.invalidate() }
    }

    @objc private func advanceText() {
        index = (index + 1) % alternatives.count
        stringValue = alternatives[index]
    }

    private func installScanAnimation() {
        wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.white.cgColor,
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.white.cgColor,
        ]
        gradient.locations = [0, 0.5, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.mask = gradient
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = -80
        animation.toValue = 120
        animation.duration = 1.55
        animation.repeatCount = .infinity
        gradient.add(animation, forKey: "scan")
    }

    override func layout() {
        super.layout()
        layer?.mask?.frame = bounds.insetBy(dx: -40, dy: 0)
    }
}

@MainActor
private class NativeLabel: NSTextField {
    init(
        _ value: String,
        font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
        color: NSColor = .labelColor,
        selectable: Bool = false
    ) {
        super.init(frame: .zero)
        stringValue = value
        self.font = font
        textColor = color
        isEditable = false
        isSelectable = selectable
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        preferredMaxLayoutWidth = max(1, bounds.width)
        super.layout()
    }
}

@MainActor
private final class NativeStack: NSStackView {
    static func vertical(spacing: CGFloat = Metrics.Space.s) -> NativeStack {
        let view = NativeStack()
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = spacing
        return view
    }
    static func horizontal(spacing: CGFloat = Metrics.Space.s) -> NativeStack {
        let view = NativeStack()
        view.orientation = .horizontal
        view.alignment = .centerY
        view.spacing = spacing
        return view
    }

    override func addArrangedSubview(_ view: NSView) {
        super.addArrangedSubview(view)
        guard orientation == .vertical else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    override func insertArrangedSubview(_ view: NSView, at index: Int) {
        super.insertArrangedSubview(view, at: index)
        guard orientation == .vertical else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    func removeAllArrangedSubviews() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

@MainActor
private final class NativeSpacer: NSView {
    init(height: CGFloat) {
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
private final class NativeCard: NSView {
    var fillProvider: () -> NSColor = {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.2)
    }
    var strokeProvider: (() -> NSColor)?
    var onLayout: (() -> Void)?
    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0
        updateLayer()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = fillProvider().cgColor
        if let strokeProvider {
            layer?.borderWidth = 1
            layer?.borderColor = strokeProvider().cgColor
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        onLayout?()
    }
    func setContent(
        _ view: NSView,
        insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    ) {
        addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }
}

@MainActor
private class NativeButton: NSButton {
    var handler: (() -> Void)?
    init(title: String = "", bordered: Bool = false, prominent: Bool = false) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = bordered ? .rounded : .inline
        isBordered = bordered
        if prominent {
            bezelColor = .controlAccentColor
            contentTintColor = .white
        }
        controlSize = .small
        target = self
        action = #selector(run)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }
    convenience init(symbol: String, help: String) {
        self.init()
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        imagePosition = .imageOnly
        toolTip = help
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    @objc private func run() { handler?() }
}

@MainActor
private final class NativeCopyButton: NativeButton {
    private let copiedImage = NSImage(
        systemSymbolName: "checkmark",
        accessibilityDescription: String(localized: "Copied")
    )
    private let copyImage = NSImage(
        systemSymbolName: "doc.on.doc",
        accessibilityDescription: String(localized: "Copy")
    )
    private var resetWorkItem: DispatchWorkItem?

    init(text: String) {
        super.init()
        let help = String(localized: "Copy")
        image = copyImage
        imagePosition = .imageOnly
        toolTip = help
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        handler = { [weak self] in
            guard copyToPasteboard(text), let self else { return }
            image = copiedImage
            toolTip = String(localized: "Copied")
            resetWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.image = self?.copyImage
                self?.toolTip = String(localized: "Copy")
            }
            resetWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
