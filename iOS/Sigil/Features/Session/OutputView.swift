import SwiftUI
import UIKit

/// The session's output. A text view rather than `Text`, because scrollback runs
/// to hundreds of kilobytes and the reader needs to select and copy from it.
struct OutputView: UIViewRepresentable {
    let text: String
    let revision: Int
    let highlight: String
    let onNearTop: () -> Void
    @Binding var atBottom: Bool
    /// Bumped by the "Latest" button to jump to the end.
    let scrollToEnd: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = []
        view.delegate = context.coordinator
        view.accessibilityLabel = "Session output"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let changed = coordinator.revision != revision || coordinator.highlight != highlight
        // A repaint drops a selection the reader is making; the next poll repaints instead.
        let selecting = view.selectedRange.length > 0 && coordinator.highlight == highlight
        if changed, !selecting {
            let wasAtBottom = coordinator.isAtBottom(view)
            let fromEnd = view.contentSize.height - view.contentOffset.y
            let prepended = coordinator.text.count < text.count && text.hasSuffix(coordinator.text) && !coordinator.text.isEmpty
            coordinator.revision = revision
            coordinator.highlight = highlight
            coordinator.text = text
            view.attributedText = Self.attributed(text, highlight: highlight)
            view.layoutIfNeeded()
            if wasAtBottom || coordinator.first {
                coordinator.scrollToBottom(view)
            } else if prepended {
                // Older text went in above the reader. Keep the lines they were reading in place.
                view.contentOffset.y = max(0, view.contentSize.height - fromEnd)
            }
            coordinator.first = false
            if !highlight.isEmpty { coordinator.scrollToFirstMatch(view, highlight) }
        }
        if coordinator.scrollToEnd != scrollToEnd {
            coordinator.scrollToEnd = scrollToEnd
            coordinator.scrollToBottom(view)
        }
    }

    static func attributed(_ text: String, highlight: String) -> NSAttributedString {
        let base = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: base)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph])
        if !highlight.isEmpty {
            let source = text as NSString
            var range = NSRange(location: 0, length: source.length)
            while true {
                let found = source.range(of: highlight, options: [.caseInsensitive], range: range)
                guard found.location != NSNotFound, found.length > 0 else { break }
                result.addAttributes(
                    [.backgroundColor: UIColor.systemBlue.withAlphaComponent(0.35)], range: found)
                let next = found.location + found.length
                range = NSRange(location: next, length: source.length - next)
            }
        }
        return result
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: OutputView
        var revision = -1
        var highlight = ""
        var text = ""
        var first = true
        var scrollToEnd = 0

        init(_ parent: OutputView) {
            self.parent = parent
            scrollToEnd = parent.scrollToEnd
        }

        func isAtBottom(_ view: UITextView) -> Bool {
            view.contentSize.height - view.contentOffset.y - view.bounds.height + view.adjustedContentInset.bottom < 60
        }

        func scrollToBottom(_ view: UITextView) {
            let y = max(
                -view.adjustedContentInset.top,
                view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
            view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            report(view)
        }

        func scrollToFirstMatch(_ view: UITextView, _ query: String) {
            let found = (text as NSString).range(of: query, options: [.caseInsensitive, .backwards])
            guard found.location != NSNotFound else { return }
            view.scrollRangeToVisible(found)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = scrollView as? UITextView else { return }
            report(view)
            if view.contentOffset.y + view.adjustedContentInset.top < 48, view.contentSize.height > view.bounds.height {
                parent.onNearTop()
            }
        }

        private func report(_ view: UITextView) {
            let bottom = isAtBottom(view)
            if parent.atBottom != bottom {
                DispatchQueue.main.async { self.parent.atBottom = bottom }
            }
        }
    }
}
