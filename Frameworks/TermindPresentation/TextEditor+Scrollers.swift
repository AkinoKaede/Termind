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
    private struct TextEditorScrollViewConfigurator: NSViewRepresentable {
        final class ResolverView: NSView {
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                configureAfterLayout()
            }

            override func layout() {
                super.layout()
                configureScrollView()
            }

            func configureAfterLayout() {
                Task { @MainActor [weak self] in self?.configureScrollView() }
            }

            private func configureScrollView() {
                guard let contentView = window?.contentView, !bounds.isEmpty,
                    let scrollView = textEditorScrollView(in: contentView)
                else { return }

                guard !scrollView.autohidesScrollers || !scrollView.hasVerticalScroller else { return }
                scrollView.hasVerticalScroller = true
                scrollView.autohidesScrollers = true
                scrollView.tile()
            }

            private func textEditorScrollView(in root: NSView) -> NSScrollView? {
                let targetFrame = convert(bounds, to: root)
                let targetCenter = NSPoint(x: targetFrame.midX, y: targetFrame.midY)
                return descendantScrollViews(in: root).first { scrollView in
                    guard let textView = scrollView.documentView as? NSTextView, textView.isEditable else {
                        return false
                    }
                    return scrollView.convert(scrollView.bounds, to: root).contains(targetCenter)
                }
            }

            private func descendantScrollViews(in root: NSView) -> [NSScrollView] {
                var result: [NSScrollView] = []
                func visit(_ view: NSView) {
                    if let scrollView = view as? NSScrollView { result.append(scrollView) }
                    view.subviews.forEach(visit)
                }
                visit(root)
                return result
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
