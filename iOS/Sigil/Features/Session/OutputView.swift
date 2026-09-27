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
    /// Its top edge, in the window's space; the view insets whatever lies below.
    var coverTop: CGFloat?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 2, so panel paragraphs can draw their own full-width background.
        let view = OutputTextView(usingTextLayoutManager: true)
        view.textLayoutManager?.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        // Selection and its handles in Beautiful UI's accent.
        view.tintColor = UIColor(Theme.accent)
        view.alwaysBounceVertical = true
        // The page already sits 8pt in from the screen's edges.
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
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
        (view as? OutputTextView)?.coverTop = coverTop
        let changed = coordinator.revision != revision || coordinator.highlight != highlight
        // A repaint drops a selection the reader is making; the next poll repaints instead.
        let selecting = view.selectedRange.length > 0 && coordinator.highlight == highlight
        if changed, !selecting {
            let wasAtBottom = coordinator.isAtBottom(view)
            let fromEnd = view.contentSize.height - view.contentOffset.y
            let previous = coordinator.text
            let repaint = coordinator.revision != revision
            coordinator.revision = revision
            coordinator.highlight = highlight
            coordinator.text = text
            // A new query leaves the text alone; only its marks change.
            if repaint { coordinator.show(self, in: view) }
            coordinator.find(highlight, in: view)
            view.layoutIfNeeded()
            if wasAtBottom || coordinator.first {
                coordinator.scrollToBottom(view)
            } else if previous.count < text.count && text.hasSuffix(previous) && !previous.isEmpty {
                // Older text went in above the reader. Keep the lines they were reading in place.
                view.contentOffset.y = max(0, view.contentSize.height - fromEnd)
            }
            coordinator.first = false
        }
        if coordinator.scrollToEnd != scrollToEnd {
            coordinator.scrollToEnd = scrollToEnd
            coordinator.scrollToBottom(view)
        }
    }

    nonisolated static func attributed(
        _ styled: StyledText, palette: [String], foreground: String = "", background: String = ""
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
        return result
    }

    /// A find match: Beautiful UI's accent, half clear. Fixed rather than
    /// adaptive, because the ground under it is the terminal theme's, not the phone's.
    nonisolated private static let match = color(0x3D9AFF).withAlphaComponent(0.35)

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
        /// What the text view holds and the look it was styled with, so the next
        /// output replaces only the lines that changed.
        private var shown: StyledText?
        private var look: Look?
        /// The find matches, in order, the text whose matches TextKit marks, and
        /// the search that finds them. A test may hold the search's queue.
        private var matches: [NSRange] = []
        private var marked = IndexSet()
        var finder = OutputFinder()

        private struct Look: Equatable {
            var palette: [String]
            var foreground: String
            var background: String
            var size: CGFloat
        }

        init(_ parent: OutputView) {
            self.parent = parent
            scrollToEnd = parent.scrollToEnd
        }

        /// Styles only the changed lines and swaps them in, in one transaction, so
        /// TextKit lays out only those again. A new look styles it all.
        func show(_ output: OutputView, in view: UITextView) {
            let look = Look(
                palette: output.palette, foreground: output.foreground, background: output.background,
                size: OutputView.font(bold: false).pointSize)
            defer { self.look = look }
            if look == self.look, let held = shown, view.textStorage.length == held.text.utf16.count,
                let all = held.edits(to: output.styled)
            {
                shown = output.styled
                let edits = all.filter { !$0.isEmpty }
                guard let top = edits.last else { return }
                // Last first, so each range still holds when its turn comes.
                let changes = edits.map { edit in
                    (NSRange(location: edit.range.lowerBound, length: edit.range.count), OutputView.attributed(
                        edit.replacement, palette: output.palette, foreground: output.foreground,
                        background: output.background))
                }
                let storage = view.textStorage
                if let manager = view.textLayoutManager, let content = manager.textContentManager {
                    content.performEditingTransaction {
                        for (range, lines) in changes { storage.replaceCharacters(in: range, with: lines) }
                    }
                    // TextKit can leave a line after the edit where it was; place them again.
                    // A top cut in an edit of its own, the last of two, moves every line
                    // under it alike, and TextKit places those itself. Laying all of them
                    // out again takes tens of milliseconds and can leave none on screen.
                    var from = top.range.lowerBound
                    if edits.count > 1 {
                        let (cut, lead) = changes[changes.count - 1]
                        from = edits[edits.count - 2].range.lowerBound + lead.length - cut.length
                    }
                    if let start = content.location(content.documentRange.location, offsetBy: from),
                        let rest = NSTextRange(location: start, end: content.documentRange.endLocation)
                    {
                        manager.invalidateLayout(for: rest)
                    }
                } else {
                    for (range, lines) in changes { storage.replaceCharacters(in: range, with: lines) }
                }
                // Marks move with their text until the search of the new text lands.
                if !matches.isEmpty {
                    mark(edits.reduce(matches) { OutputFind.matches($0, after: $1) }, in: view)
                }
                return
            }
            view.attributedText = OutputView.attributed(
                output.styled, palette: output.palette, foreground: output.foreground, background: output.background)
            shown = output.styled
            if !matches.isEmpty { mark([], in: view) }
        }

        /// Searches the output off the main thread, marks what it finds and shows
        /// the last match, unless the output or the query moved on meanwhile.
        func find(_ query: String, in view: UITextView) {
            guard !query.isEmpty else {
                if !matches.isEmpty { mark([], in: view) }
                return
            }
            let text = text
            let revision = revision
            Task { [weak self, weak view] in
                guard let found = await self?.finder.matches(of: query, in: text), let self, let view,
                    self.highlight == query, self.revision == revision
                else { return }
                if found != self.matches { self.mark(found, in: view) }
                if let last = found.last { view.scrollRangeToVisible(last) }
            }
        }

        /// Swaps the marks. They are TextKit rendering attributes, drawn over the
        /// text, so the terminal's own colours are back the moment they go.
        private func mark(_ found: [NSRange], in view: UITextView) {
            matches = found
            marked = IndexSet()
            guard let manager = view.textLayoutManager else { return }
            manager.removeRenderingAttribute(.backgroundColor, for: manager.documentRange)
            markNearby(in: view)
            // Lines on screen draw again only when laid out.
            manager.textViewportLayoutController.layoutViewport()
        }

        /// Marks the matches within a screen of what shows, where not marked yet;
        /// scrolling marks the rest as it comes near.
        private func markNearby(in view: UITextView) {
            guard !matches.isEmpty, let manager = view.textLayoutManager, let content = manager.textContentManager
            else { return }
            let bottom = max(0, manager.usageBoundsForTextContainer.maxY - 1)
            let top = view.contentOffset.y - view.textContainerInset.top - view.bounds.height
            let origin = content.documentRange.location
            let first = manager.textLayoutFragment(for: CGPoint(x: 0, y: min(max(0, top), bottom)))
            let last = manager.textLayoutFragment(for: CGPoint(x: 0, y: min(max(0, top + 3 * view.bounds.height), bottom)))
            let start = content.offset(from: origin, to: first?.rangeInElement.location ?? origin)
            let end = content.offset(from: origin, to: last?.rangeInElement.endLocation ?? content.documentRange.endLocation)
            guard start < end else { return }
            let near = NSRange(location: start, length: end - start)
            for match in OutputFind.matches(matches, in: near, besides: marked) {
                guard let from = content.location(origin, offsetBy: match.location),
                    let to = content.location(from, offsetBy: match.length),
                    let range = NSTextRange(location: from, end: to)
                else { continue }
                manager.addRenderingAttribute(.backgroundColor, value: OutputView.match, for: range)
            }
            marked.insert(integersIn: start..<end)
        }

        func isAtBottom(_ view: UITextView) -> Bool {
            view.contentSize.height - view.contentOffset.y - view.bounds.height + view.adjustedContentInset.bottom < 60
        }

        /// TextKit 2 guesses the height of lines it has not laid out; laying out
        /// the end corrects the guess, so this repeats until the end holds still.
        func scrollToBottom(_ view: UITextView) {
            var y = CGFloat.nan
            for _ in 0..<4 {
                let end = max(
                    -view.adjustedContentInset.top,
                    view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom)
                if end == y { break }
                y = end
                view.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                view.layoutIfNeeded()
            }
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

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = scrollView as? UITextView else { return }
            report(view)
            markNearby(in: view)
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
    /// Where the composer starts, in the window. The view runs on under it to the
    /// page's foot, so all of that is inset, not just the composer's own height.
    var coverTop: CGFloat? {
        didSet { if coverTop != oldValue { setNeedsLayout() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        var covered: CGFloat = 0
        if let coverTop, window != nil, let superview {
            covered = max(0, superview.convert(frame, to: nil).maxY - coverTop)
        }
        if contentInset.bottom != covered {
            contentInset.bottom = covered
            verticalScrollIndicatorInsets.bottom = covered
        }
    }

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
