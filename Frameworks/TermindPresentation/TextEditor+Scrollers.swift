import SwiftUI

#if os(macOS)
    import AppKit
#endif

extension TextEditor {
    /// Hides an unused macOS scroller without suppressing it for overflowing text.
    public func autohidingScrollers() -> some View {
        #if os(macOS)
            background { TextEditorScrollViewConfigurator() }
        #else
            self
        #endif
    }
}

#if os(macOS)
    /// Makes AppKit hide the TextEditor's vertical scroller while its document fits.
    ///
    /// SwiftUI's scroll-indicator visibility does not remove the disabled scroller
    /// from a macOS TextEditor when the system is configured to always show scroll
    /// bars. The underlying NSScrollView already knows whether its document exceeds
    /// the clip view, so leave that decision to `autohidesScrollers` instead of
    /// duplicating it from an approximate text-height measurement.
    struct TextEditorScrollViewConfigurator: NSViewRepresentable {
        final class ResolverView: NSView {
            private weak var cachedScrollView: NSScrollView?
            private var resolverAncestors: [ObjectIdentifier] = []
            private var targetAncestors: [ObjectIdentifier] = []

            override func viewDidMoveToSuperview() {
                super.viewDidMoveToSuperview()
                invalidateTarget()
                configureAfterLayout()
            }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                invalidateTarget()
                configureAfterLayout()
            }

            private func invalidateTarget() {
                cachedScrollView = nil
                resolverAncestors = []
                targetAncestors = []
            }

            override func layout() {
                super.layout()
                configureScrollView()
            }

            func configureAfterLayout() {
                Task { @MainActor [weak self] in self?.configureScrollView() }
            }

            func configureScrollView() {
                guard let contentView = window?.contentView, !bounds.isEmpty else { return }
                let scrollView: NSScrollView
                if let cached = cachedScrollView,
                    resolverAncestors == ancestors(of: self), targetAncestors == ancestors(of: cached),
                    matches(cached, in: contentView)
                {
                    scrollView = cached
                } else {
                    invalidateTarget()
                    guard let resolved = textEditorScrollView(in: contentView) else { return }
                    scrollView = resolved
                    cachedScrollView = resolved
                    resolverAncestors = ancestors(of: self)
                    targetAncestors = ancestors(of: resolved)
                }

                guard !scrollView.autohidesScrollers || !scrollView.hasVerticalScroller else { return }
                scrollView.hasVerticalScroller = true
                scrollView.autohidesScrollers = true
                scrollView.tile()
            }

            private func ancestors(of view: NSView) -> [ObjectIdentifier] {
                var result: [ObjectIdentifier] = []
                var cursor = view.superview
                while let ancestor = cursor {
                    result.append(ObjectIdentifier(ancestor))
                    cursor = ancestor.superview
                }
                return result
            }

            private func matches(_ scrollView: NSScrollView, in root: NSView) -> Bool {
                guard scrollView.window === window, scrollView.isDescendant(of: root),
                    !scrollView.isHiddenOrHasHiddenAncestor,
                    let textView = scrollView.documentView as? NSTextView, textView.isEditable
                else { return false }
                let targetFrame = convert(bounds, to: root)
                return scrollView.convert(scrollView.bounds, to: root).contains(
                    NSPoint(x: targetFrame.midX, y: targetFrame.midY))
            }

            private func textEditorScrollView(in root: NSView) -> NSScrollView? {
                func find(in view: NSView) -> NSScrollView? {
                    if let scrollView = view as? NSScrollView, matches(scrollView, in: root) { return scrollView }
                    for child in view.subviews {
                        if let match = find(in: child) { return match }
                    }
                    return nil
                }
                return find(in: root)
            }
        }

        func makeNSView(context: Context) -> ResolverView {
            ResolverView(frame: .zero)
        }

        func updateNSView(_ nsView: ResolverView, context: Context) {
            nsView.configureAfterLayout()
        }
    }

#endif
