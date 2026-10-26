// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit

/// Fit the actual labels rather than using a platform or device-width breakpoint.
@MainActor
final class NativeResourceAdaptiveStack: NSStackView {
    private var horizontalWidth: CGFloat = 0
    private var verticalConstraints: [NSLayoutConstraint] = []
    private let forceVertical: Bool

    init(forceVertical: Bool = false) {
        self.forceVertical = forceVertical
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func addResourceView(_ view: NSView, width: CGFloat) {
        if !arrangedSubviews.isEmpty { horizontalWidth += spacing }
        horizontalWidth += width
        addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        let constraint = view.widthAnchor.constraint(equalTo: widthAnchor)
        constraint.isActive = true
        verticalConstraints.append(constraint)
    }

    override func layout() {
        let vertical = forceVertical || bounds.width < horizontalWidth
        let desired: NSUserInterfaceLayoutOrientation = vertical ? .vertical : .horizontal
        if orientation != desired {
            NSLayoutConstraint.deactivate(verticalConstraints)
            orientation = desired
            alignment = vertical ? .leading : .top
            if vertical { NSLayoutConstraint.activate(verticalConstraints) }
        }
        super.layout()
    }
}

/// Public material and scripts remain selectable, but can never grow a transcript row without bound.
@MainActor
final class NativeResourceText: NSScrollView {
    init(text: String, font: NSFont) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        let body = NSTextView()
        body.isEditable = false
        body.isSelectable = true
        body.isRichText = false
        body.drawsBackground = false
        body.font = font
        body.textColor = .labelColor
        body.string = text
        body.isHorizontallyResizable = false
        body.isVerticallyResizable = true
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        body.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        documentView = body
        heightAnchor.constraint(
            equalToConstant: min(200, max(64, CGFloat(text.components(separatedBy: "\n").count) * 18))
        ).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        guard let body = documentView as? NSTextView, contentSize.width > 0 else { return }
        body.setFrameSize(NSSize(width: contentSize.width, height: max(body.frame.height, contentSize.height)))
        body.textContainer?.containerSize.width = contentSize.width
        body.sizeToFit()
    }
}
