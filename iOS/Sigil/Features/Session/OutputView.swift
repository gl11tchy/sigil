import SwiftUI
import UIKit

/// The session's output. A text view rather than `Text`, because scrollback runs
/// to hundreds of kilobytes and the reader needs to select and copy from it.
struct OutputView: UIViewRepresentable {
    let styled: StyledText
    /// The terminal theme's 16 colours, as `RRGGBB`; empty when the Mac sent none.
    let palette: [String]
    /// The theme's default text and background; empty falls back to the system's.
    let foreground: String
    let background: String
    let revision: Int
    let highlight: String

    var text: String { styled.text }
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
        view.backgroundColor = UInt32(background, radix: 16).map(Self.color) ?? .clear
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
            view.attributedText = Self.attributed(
                styled, palette: palette, foreground: foreground, highlight: highlight)
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

    nonisolated static func attributed(
        _ styled: StyledText, palette: [String], foreground: String = "", highlight: String
    ) -> NSAttributedString {
        let text = styled.text
        let defaultText = UInt32(foreground, radix: 16).map(Self.color) ?? UIColor.label
        let base = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: base)
        let bold = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: UIFont.monospacedSystemFont(ofSize: 13, weight: .bold))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let result = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: defaultText, .paragraphStyle: paragraph])
        let length = (text as NSString).length
        for span in styled.spans {
            guard span.location >= 0, span.length > 0, span.location + span.length <= length else { continue }
            let range = NSRange(location: span.location, length: span.length)
            var attributes: [NSAttributedString.Key: Any] = [:]
            var foreground = StyledOutput.rgb(span.fg, palette: palette).map(Self.color)
            var background = StyledOutput.rgb(span.bg, palette: palette).map(Self.color)
            if span.flags & StyledSpan.inverse != 0 {
                // Inverse video: the terminal swaps the two, so the phone does as well.
                swap(&foreground, &background)
                foreground = foreground ?? UIColor.systemBackground
                background = background ?? UIColor.label
            }
            if let foreground {
                attributes[.foregroundColor] =
                    span.flags & StyledSpan.dim != 0 ? foreground.withAlphaComponent(0.6) : foreground
            } else if span.flags & StyledSpan.dim != 0 {
                attributes[.foregroundColor] = defaultText.withAlphaComponent(0.6)
            }
            if let background { attributes[.backgroundColor] = background }
            if span.flags & StyledSpan.bold != 0 { attributes[.font] = bold }
            if span.flags & StyledSpan.italic != 0 { attributes[.obliqueness] = 0.2 }
            if span.flags & StyledSpan.underline != 0 { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if span.flags & StyledSpan.crossedOut != 0 {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if !attributes.isEmpty { result.addAttributes(attributes, range: range) }
        }
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

    nonisolated private static func color(_ rgb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
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
