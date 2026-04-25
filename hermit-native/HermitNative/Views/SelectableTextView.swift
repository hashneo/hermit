import SwiftUI

// MARK: - SelectableTextView
// Cross-platform NSTextView/UITextView wrapper.
// - Full OS-level text selection (cursor, drag, double-click, Copy)
// - "Quote & Comment" in the system context/selection menu
// - onQuoteSelected(text)            — fired when that menu item is chosen
// - onSelectionChanged(text?, rect)  — fired on every selection change;
//   nil text = deselected. rect is in the view's own coordinate space.

#if os(macOS)
import AppKit

struct SelectableTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    var onQuoteSelected: ((String) -> Void)? = nil
    var onSelectionChanged: ((String?, CGRect) -> Void)? = nil
    /// Fired when the user clicks without making a text selection (i.e. a plain tap).
    var onTapped: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QuotableNSTextView {
        let tv = QuotableNSTextView()
        tv.delegate = context.coordinator
        tv.onQuoteSelected = onQuoteSelected
        tv.onSelectionChanged = onSelectionChanged
        tv.onTapped = onTapped
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textStorage?.setAttributedString(attributedText)
        return tv
    }

    func updateNSView(_ nsView: QuotableNSTextView, context: Context) {
        nsView.onQuoteSelected = onQuoteSelected
        nsView.onSelectionChanged = onSelectionChanged
        nsView.onTapped = onTapped
        if nsView.attributedString() != attributedText {
            nsView.textStorage?.setAttributedString(attributedText)
        }
        nsView.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? QuotableNSTextView)?.reportSelection()
        }
    }
}

final class QuotableNSTextView: NSTextView {
    var onQuoteSelected: ((String) -> Void)?
    var onSelectionChanged: ((String?, CGRect) -> Void)?
    var onTapped: (() -> Void)?

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else { return super.intrinsicContentSize }
        lm.ensureLayout(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(lm.usedRect(for: tc).height))
    }

    // Forward single clicks (no drag, no selection) to SwiftUI as a tap.
    // This allows code blocks and list items to open the comment composer
    // even though NSTextView normally consumes all mouse events.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if selectedRange().length == 0 {
            onTapped?()
        }
    }

    func reportSelection() {
        let range = selectedRange()
        guard range.length > 0 else {
            onSelectionChanged?(nil, .zero)
            return
        }
        let text = (string as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        var selRect = CGRect.zero
        if let lm = layoutManager, let tc = textContainer {
            let gr = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: gr, in: tc)
            r.origin.y += textContainerInset.height
            r.origin.x += textContainerInset.width
            selRect = r
        }
        onSelectionChanged?(text.isEmpty ? nil : text, selRect)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        let sel = string[Range(selectedRange(), in: string) ?? string.startIndex..<string.endIndex]
        if !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = NSMenuItem(title: "Quote & Comment",
                                  action: #selector(quoteAndComment(_:)),
                                  keyEquivalent: "")
            item.target = self
            base.insertItem(item, at: 0)
            base.insertItem(.separator(), at: 1)
        }
        return base
    }

    @objc func quoteAndComment(_ sender: Any?) {
        let sel = string[Range(selectedRange(), in: string) ?? string.startIndex..<string.endIndex]
        let text = String(sel).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { onQuoteSelected?(text) }
    }
}

#else
import UIKit

struct SelectableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    var onQuoteSelected: ((String) -> Void)? = nil
    var onSelectionChanged: ((String?, CGRect) -> Void)? = nil
    /// Fired when the user taps without making a text selection.
    var onTapped: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onQuoteSelected: onQuoteSelected, onSelectionChanged: onSelectionChanged)
    }

    func makeUIView(context: Context) -> QuotableUITextView {
        let tv = QuotableUITextView()
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        tv.onTapped = onTapped
        tv.attributedText = attributedText
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.setContentHuggingPriority(.required, for: .vertical)
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ uiView: QuotableUITextView, context: Context) {
        context.coordinator.onQuoteSelected = onQuoteSelected
        context.coordinator.onSelectionChanged = onSelectionChanged
        uiView.coordinator = context.coordinator
        uiView.onTapped = onTapped
        if uiView.attributedText != attributedText {
            uiView.attributedText = attributedText
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onQuoteSelected: ((String) -> Void)?
        var onSelectionChanged: ((String?, CGRect) -> Void)?

        init(onQuoteSelected: ((String) -> Void)?, onSelectionChanged: ((String?, CGRect) -> Void)?) {
            self.onQuoteSelected = onQuoteSelected
            self.onSelectionChanged = onSelectionChanged
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? QuotableUITextView)?.reportSelection()
        }
    }
}

final class QuotableUITextView: UITextView {
    weak var coordinator: SelectableTextView.Coordinator?
    var onTapped: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Add a tap recogniser that fires onTapped when no text is selected.
        // requiresExclusiveTouchType = false so it coexists with UITextView's own gestures.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        if selectedTextRange?.isEmpty ?? true {
            onTapped?()
        }
    }

    override var intrinsicContentSize: CGSize {
        layoutIfNeeded()
        return contentSize
    }

    func reportSelection() {
        guard let range = selectedTextRange, !range.isEmpty else {
            coordinator?.onSelectionChanged?(nil, .zero)
            return
        }
        let text = self.text(in: range)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rects = selectionRects(for: range).map { $0.rect }
        let union = rects.reduce(CGRect.null) { $0.union($1) }
        coordinator?.onSelectionChanged?(text.isEmpty ? nil : text, union)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(quoteAndComment(_:)) {
            return !(selectedTextRange?.isEmpty ?? true)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        if #available(iOS 16.0, *) {
            let action = UIAction(title: "Quote & Comment",
                                  image: UIImage(systemName: "quote.bubble")) { [weak self] _ in
                self?.quoteAndComment(nil)
            }
            builder.insertSibling(
                UIMenu(title: "", options: .displayInline, children: [action]),
                afterMenu: .edit
            )
        }
    }

    @objc func quoteAndComment(_ sender: Any?) {
        guard let range = selectedTextRange,
              let text = self.text(in: range)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        coordinator?.onQuoteSelected?(text)
    }
}
#endif

// MARK: - NSAttributedString helpers

extension Array where Element == MarkdownInline {
#if os(macOS)
    func nsAttributedString(font: NSFont? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in self { result.append(inline.nsAttributedString(baseFont: font)) }
        return result
    }
#else
    func nsAttributedString(font: UIFont? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in self { result.append(inline.nsAttributedString(baseFont: font)) }
        return result
    }
#endif
}

extension MarkdownInline {
#if os(macOS)
    func nsAttributedString(baseFont: NSFont? = nil) -> NSAttributedString {
        let bodyFont = baseFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        switch self {
        case .text(let s):
            return NSAttributedString(string: s, attributes: [.font: bodyFont, .foregroundColor: NSColor.labelColor])
        case .bold(let children):
            let bold = NSFont.boldSystemFont(ofSize: bodyFont.pointSize)
            return NSMutableAttributedString(attributedString: children.nsAttributedString(font: bold))
        case .italic(let children):
            let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
            return NSMutableAttributedString(attributedString: children.nsAttributedString(font: italic))
        case .code(let s):
            let mono = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular)
            return NSAttributedString(string: s, attributes: [
                .font: mono,
                .backgroundColor: NSColor(red: 0.92, green: 0.98, blue: 0.92, alpha: 1.0),  // light green
                .foregroundColor: NSColor.labelColor
            ])
        case .link(let text, let url):
            var attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: NSColor.controlAccentColor]
            if let u = URL(string: url) { attrs[.link] = u }
            return NSAttributedString(string: text, attributes: attrs)
        case .image(let alt, _):
            return NSAttributedString(string: "[\(alt)]", attributes: [.font: bodyFont, .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
#else
    func nsAttributedString(baseFont: UIFont? = nil) -> NSAttributedString {
        let bodyFont = baseFont ?? UIFont.preferredFont(forTextStyle: .body)
        switch self {
        case .text(let s):
            return NSAttributedString(string: s, attributes: [.font: bodyFont, .foregroundColor: UIColor.label])
        case .bold(let children):
            let bold = UIFont.boldSystemFont(ofSize: bodyFont.pointSize)
            return NSMutableAttributedString(attributedString: children.nsAttributedString(font: bold))
        case .italic(let children):
            let desc = bodyFont.fontDescriptor.withSymbolicTraits(.traitItalic) ?? bodyFont.fontDescriptor
            let italic = UIFont(descriptor: desc, size: bodyFont.pointSize)
            return NSMutableAttributedString(attributedString: children.nsAttributedString(font: italic))
        case .code(let s):
            let mono = UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular)
            return NSAttributedString(string: s, attributes: [
                .font: mono,
                .backgroundColor: UIColor(red: 0.92, green: 0.98, blue: 0.92, alpha: 1.0),  // light green
                .foregroundColor: UIColor.label
            ])
        case .link(let text, let url):
            var attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: UIColor.systemBlue]
            if let u = URL(string: url) { attrs[.link] = u }
            return NSAttributedString(string: text, attributes: attrs)
        case .image(let alt, _):
            return NSAttributedString(string: "[\(alt)]", attributes: [.font: bodyFont, .foregroundColor: UIColor.secondaryLabel])
        }
    }
#endif
}
