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
    /// The composer floats over the output's bottom; the last line scrolls clear of it.
    var composerHeight: CGFloat = 0

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 2, so panel paragraphs can draw their own full-width background.
        let view = OutputTextView(usingTextLayoutManager: true)
        view.textLayoutManager?.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.dataDetectorTypes = []
        view.delegate = context.coordinator
        view.accessibilityLabel = "Session output"
        view.insetChanged = { [weak coordinator = context.coordinator] view in
            if coordinator?.parent.atBottom == true { coordinator?.scrollToBottom(view) }
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // A full-screen program's own ground wins over the terminal theme's.
        view.backgroundColor =
            StyledOutput.rgb(styled.ground, palette: palette).map(Self.color)
            ?? UInt32(background, radix: 16).map(Self.color) ?? .clear
        if view.contentInset.bottom != composerHeight {
            view.contentInset.bottom = composerHeight
            view.verticalScrollIndicatorInsets.bottom = composerHeight
        }
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
                styled, palette: palette, foreground: foreground, background: background, highlight: highlight)
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
        _ styled: StyledText, palette: [String], foreground: String = "", background: String = "", highlight: String
    ) -> NSAttributedString {
        let text = styled.text
        let defaultText = UInt32(foreground, radix: 16).map(Self.color) ?? UIColor.label
        let font = Self.font(bold: false)
        let bold = Self.font(bold: true)
        let result = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: defaultText])
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
        let base = StyledOutput.rgb(styled.ground, palette: palette) ?? UInt32(background, radix: 16)
        Self.shapeParagraphs(result, panels: styled.panels, palette: palette, base: base, font: font)
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

    /// The Mac terminal's face, JetBrains Mono, sized with the reader's text size.
    nonisolated static func font(bold: Bool) -> UIFont {
        let base =
            UIFont(name: bold ? "JetBrainsMono-Bold" : "JetBrainsMono-Regular", size: 13)
            ?? UIFont.monospacedSystemFont(ofSize: 13, weight: bold ? .bold : .regular)
        return UIFontMetrics(forTextStyle: .footnote).scaledFont(for: base)
    }

    /// Each line wraps under the text after its indent and list marker, and a
    /// panel line carries its colour and padding for `PanelLayoutFragment`.
    nonisolated private static func shapeParagraphs(
        _ result: NSMutableAttributedString, panels: [StyledPanel], palette: [String], base: UInt32?, font: UIFont
    ) {
        let source = result.string as NSString
        var styles: [ParagraphKey: NSParagraphStyle] = [:]
        var widths: [String: CGFloat] = [:]
        var next = 0
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byParagraphs) {
            line, range, enclosing, _ in
            while next < panels.count, panels[next].location < range.location { next += 1 }
            let panel = next < panels.count && panels[next].location == range.location ? panels[next] : nil
            let prefix = StyledOutput.hangingPrefix(line ?? "")
            var indent: CGFloat = 0
            if prefix > 0 {
                let head = source.substring(with: NSRange(location: range.location, length: prefix))
                indent = widths[head] ?? (head as NSString).size(withAttributes: [.font: font]).width
                widths[head] = indent
            }
            let key = ParagraphKey(indent: indent, top: panel?.top == true, bottom: panel?.bottom == true)
            let style = styles[key] ?? key.style
            styles[key] = style
            result.addAttribute(.paragraphStyle, value: style, range: enclosing)
            if let panel, let rgb = StyledOutput.rgb(panel.color, palette: palette) {
                result.addAttribute(
                    .outputPanel, value: OutputPanel(color: Self.panelColor(rgb, over: base), top: panel.top, bottom: panel.bottom),
                    range: enclosing)
            }
        }
    }

    private struct ParagraphKey: Hashable {
        var indent: CGFloat
        var top: Bool
        var bottom: Bool

        var style: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.headIndent = indent
            if top { style.paragraphSpacingBefore = PanelLayoutFragment.padding }
            if bottom { style.paragraphSpacing = PanelLayoutFragment.padding }
            return style
        }
    }

    nonisolated private static func color(_ rgb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// Half clear, mixed to read as `rgb` over the view's background: the selection
    /// highlight sits behind the text and must show through a panel.
    nonisolated private static func panelColor(_ rgb: UInt32, over base: UInt32?) -> UIColor {
        guard let base else { return color(rgb) }
        func channel(_ shift: UInt32) -> CGFloat {
            let top = CGFloat((rgb >> shift) & 0xFF) / 255
            let under = CGFloat((base >> shift) & 0xFF) / 255
            return min(max(2 * top - under, 0), 1)
        }
        return UIColor(red: channel(16), green: channel(8), blue: channel(0), alpha: 0.5)
    }

    final class Coordinator: NSObject, UITextViewDelegate, NSTextLayoutManagerDelegate {
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

        func textLayoutManager(
            _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
            in textElement: NSTextElement
        ) -> NSTextLayoutFragment {
            if let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
                let panel = paragraph.attributedString.attribute(.outputPanel, at: 0, effectiveRange: nil)
                    as? OutputPanel
            {
                return PanelLayoutFragment(textElement: textElement, range: textElement.elementRange, panel: panel)
            }
            return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
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

/// Reports inset changes: the composer and the home indicator arrive after the
/// first layout, and a reader at the end stays at the end.
final class OutputTextView: UITextView {
    var insetChanged: ((UITextView) -> Void)?

    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        insetChanged?(self)
    }
}

extension NSAttributedString.Key {
    static let outputPanel = NSAttributedString.Key("SigilOutputPanel")
}

/// A line the program painted across its width, and where it sits in its run.
final class OutputPanel: NSObject {
    let color: UIColor
    let top: Bool
    let bottom: Bool

    init(color: UIColor, top: Bool, bottom: Bool) {
        self.color = color
        self.top = top
        self.bottom = bottom
    }
}

/// Draws a panel line's background across the full width, rounding and padding
/// the ends of a run, so a prompt or a code block reads as one block.
final class PanelLayoutFragment: NSTextLayoutFragment {
    static let padding: CGFloat = 6
    static let bleed: CGFloat = 10
    static let radius: CGFloat = 10

    private let panel: OutputPanel

    init(textElement: NSTextElement, range: NSTextRange?, panel: OutputPanel) {
        self.panel = panel
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    private var panelRect: CGRect {
        let frame = layoutFragmentFrame
        let width = textLayoutManager?.textContainer?.size.width ?? frame.width
        let lines = textLineFragments
        let top = panel.top ? (lines.first?.typographicBounds.minY ?? 0) - Self.padding : 0
        let bottom = panel.bottom ? (lines.last?.typographicBounds.maxY ?? frame.height) + Self.padding : frame.height
        return CGRect(x: -frame.minX - Self.bleed, y: top, width: width + 2 * Self.bleed, height: bottom - top)
    }

    override var renderingSurfaceBounds: CGRect { super.renderingSurfaceBounds.union(panelRect) }

    override func draw(at point: CGPoint, in context: CGContext) {
        var corners: UIRectCorner = []
        if panel.top { corners.formUnion([.topLeft, .topRight]) }
        if panel.bottom { corners.formUnion([.bottomLeft, .bottomRight]) }
        let path = UIBezierPath(
            roundedRect: panelRect.offsetBy(dx: point.x, dy: point.y), byRoundingCorners: corners,
            cornerRadii: CGSize(width: Self.radius, height: Self.radius))
        context.saveGState()
        context.setFillColor(panel.color.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
        context.restoreGState()
        super.draw(at: point, in: context)
    }
}
