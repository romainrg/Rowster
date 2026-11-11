import AppKit
import RowsterCore
import SwiftUI

/// The SQL editor: an `NSTextView` on TextKit 2. Colors are rendering attributes, so highlighting never
/// touches the text or its undo history.
struct SQLEditorView: NSViewRepresentable {
    @Binding var text: String
    /// The selection, in UTF-16 units.
    @Binding var selection: NSRange
    let dialect: any SQLDialect

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        // SQL is not prose: no curly quotes, long dashes, replacements or spelling.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel(String(localized: "SQL editor"))
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let ruler = LineNumberRuler(textView: textView, scrollView: scroll)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.scrolled), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.highlight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditorView
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?

        init(_ parent: SQLEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            highlight()
            ruler?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            parent.selection = textView.selectedRange()
            highlightCurrentStatement()
        }

        @objc func scrolled() { ruler?.needsDisplay = true }

        /// Colors the tokens of the whole text.
        func highlight() {
            guard let textView, let layout = textView.textLayoutManager else { return }
            let text = textView.string
            layout.removeRenderingAttribute(.foregroundColor, for: layout.documentRange)
            for span in SQLHighlighter(dialect: parent.dialect).spans(in: text) {
                guard let range = textRange(NSRange(span.range, in: text), layout: layout) else { continue }
                layout.addRenderingAttribute(.foregroundColor, value: Self.color(span.kind), for: range)
            }
            highlightCurrentStatement()
        }

        /// Shades the statement under the cursor, so it is clear what ⌘↩ will run.
        private func highlightCurrentStatement() {
            guard let textView, let layout = textView.textLayoutManager else { return }
            layout.removeRenderingAttribute(.backgroundColor, for: layout.documentRange)
            let text = textView.string
            let statements = parent.dialect.splitter.split(text)
            guard statements.count > 1, textView.selectedRange().length == 0 else { return }
            let offset = min(textView.selectedRange().location, text.utf16.count)
            let position = String.Index(utf16Offset: offset, in: text)
            guard let current = statements.last(where: { $0.range.lowerBound <= position }) ?? statements.first,
                  let range = textRange(NSRange(current.range, in: text), layout: layout) else { return }
            layout.addRenderingAttribute(
                .backgroundColor, value: Theme.Code.currentStatement, for: range)
        }

        private func textRange(_ range: NSRange, layout: NSTextLayoutManager) -> NSTextRange? {
            guard let content = layout.textContentManager,
                  let start = content.location(layout.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length) else { return nil }
            return NSTextRange(location: start, end: end)
        }

        private static func color(_ kind: SyntaxClass) -> NSColor {
            switch kind {
            case .keyword: return Theme.Code.keyword
            case .string: return Theme.Code.string
            case .number: return Theme.Code.number
            case .comment: return .secondaryLabelColor
            case .quotedIdentifier: return Theme.Code.quotedIdentifier
            case .parameter: return Theme.Code.parameter
            }
        }
    }
}

/// Line numbers beside the editor, one per paragraph.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 38
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.textLayoutManager else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let visible = textView.visibleRect
        let inset = textView.textContainerInset.height
        var line = 0
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { fragment in
            line += 1
            let frame = fragment.layoutFragmentFrame
            if frame.maxY + inset < visible.minY { return true }
            if frame.minY + inset > visible.maxY { return false }
            let label = NSAttributedString(string: "\(line)", attributes: attributes)
            let size = label.size()
            let y = self.convert(NSPoint(x: 0, y: frame.minY + inset), from: textView).y
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 6, y: y + 2))
            return true
        }
        if line == 0 {
            NSAttributedString(string: "1", attributes: attributes).draw(at: NSPoint(x: ruleThickness - 12, y: inset + 2))
        }
    }
}
