import SwiftUI

// MARK: - SelectableTextView
// A cross-platform selectable text view that:
// 1. Renders an AttributedString with native OS text selection (cursor, copy, etc.)
// 2. Adds a "Quote & Comment" item to the system selection menu
// 3. Fires onQuoteSelected(selectedText) when that menu item is tapped
//
// Usage:
//   SelectableTextView(attributedText: myAttributedString, onQuoteSelected: { text in ... })

#if os(macOS)
import AppKit

struct SelectableTextView: NSViewRepresentable {
    let attributedText: NSAttributedString
    var onQuoteSelected: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QuotableNSTextView {
        let tv = QuotableNSTextView()
        tv.onQuoteSelected = onQuoteSelected
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
        if nsView.attributedString() != attributedText {
            nsView.textStorage?.setAttributedString(attributedText)
        }
        nsView.invalidateIntrinsicContentSize()
    }

    final class Coordinator: NSObject {}
}

// NSTextView subclass that injects "Quote & Comment" into the context menu
final class QuotableNSTextView: NSTextView {
    var onQuoteSelected: ((String) -> Void)?

    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer else {
            return super.intrinsicContentSize
        }
        lm.ensureLayout(for: tc)
        let rect = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(rect.height))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let base = super.menu(for: event) ?? NSMenu()
        let sel = string[Range(selectedRange(), in: string) ?? string.startIndex..<string.endIndex]
        if !sel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let item = NSMenuItem(
                title: "Quote & Comment",
                action: #selector(quoteAndComment(_:)),
                keyEquivalent: ""
            )
            item.target = self
            base.insertItem(item, at: 0)
            base.insertItem(NSMenuItem.separator(), at: 1)
        }
        return base
    }

    @objc private func quoteAndComment(_ sender: Any?) {
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

    func makeCoordinator() -> Coordinator { Coordinator(onQuoteSelected: onQuoteSelected) }

    func makeUIView(context: Context) -> QuotableUITextView {
        let tv = QuotableUITextView()
        tv.coordinator = context.coordinator
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
        uiView.coordinator = context.coordinator
        if uiView.attributedText != attributedText {
            uiView.attributedText = attributedText
        }
    }

    final class Coordinator: NSObject {
        var onQuoteSelected: ((String) -> Void)?
        init(onQuoteSelected: ((String) -> Void)?) { self.onQuoteSelected = onQuoteSelected }
    }
}

final class QuotableUITextView: UITextView {
    weak var coordinator: SelectableTextView.Coordinator?

    override var intrinsicContentSize: CGSize {
        // Force re-layout so the view sizes to its content
        layoutIfNeeded()
        return contentSize
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(quoteAndComment(_:)) {
            return !selectedTextRange.map { $0.isEmpty }.unwrap(default: true)
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
            let menu = UIMenu(title: "", options: .displayInline, children: [action])
            builder.insertSiblingMenu(menu, afterMenuFor: .standardEdit)
        }
    }

    @objc func quoteAndComment(_ sender: Any?) {
        guard let range = selectedTextRange,
              let text = self.text(in: range)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        coordinator?.onQuoteSelected?(text)
    }
}

private extension Optional where Wrapped == Bool {
    func unwrap(default value: Bool) -> Bool { self ?? value }
}
#endif

// MARK: - NSAttributedString from MarkdownInline
// Converts [MarkdownInline] → NSAttributedString so SelectableTextView can render it.

extension Array where Element == MarkdownInline {
    func nsAttributedString(font: NSFont? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in self {
            result.append(inline.nsAttributedString(baseFont: font))
        }
        return result
    }
}

extension MarkdownInline {
#if os(macOS)
    func nsAttributedString(baseFont: NSFont? = nil) -> NSAttributedString {
        let bodyFont = baseFont ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        switch self {
        case .text(let s):
            return NSAttributedString(string: s, attributes: [.font: bodyFont])
        case .bold(let children):
            let bold = NSFont.boldSystemFont(ofSize: bodyFont.pointSize)
            let a = children.nsAttributedString(font: bodyFont)
            let m = NSMutableAttributedString(attributedString: a)
            m.addAttribute(.font, value: bold, range: NSRange(location: 0, length: m.length))
            return m
        case .italic(let children):
            let italic = NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
            let a = children.nsAttributedString(font: bodyFont)
            let m = NSMutableAttributedString(attributedString: a)
            m.addAttribute(.font, value: italic, range: NSRange(location: 0, length: m.length))
            return m
        case .code(let s):
            let mono = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular)
            return NSAttributedString(string: s, attributes: [
                .font: mono,
                .backgroundColor: NSColor.windowBackgroundColor
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
            return NSAttributedString(string: s, attributes: [.font: bodyFont])
        case .bold(let children):
            let bold = UIFont.boldSystemFont(ofSize: bodyFont.pointSize)
            let a = children.nsAttributedString(font: bodyFont)
            let m = NSMutableAttributedString(attributedString: a)
            m.addAttribute(.font, value: bold, range: NSRange(location: 0, length: m.length))
            return m
        case .italic(let children):
            let desc = bodyFont.fontDescriptor.withSymbolicTraits(.traitItalic) ?? bodyFont.fontDescriptor
            let italic = UIFont(descriptor: desc, size: bodyFont.pointSize)
            let a = children.nsAttributedString(font: bodyFont)
            let m = NSMutableAttributedString(attributedString: a)
            m.addAttribute(.font, value: italic, range: NSRange(location: 0, length: m.length))
            return m
        case .code(let s):
            let mono = UIFont.monospacedSystemFont(ofSize: bodyFont.pointSize - 1, weight: .regular)
            return NSAttributedString(string: s, attributes: [
                .font: mono,
                .backgroundColor: UIColor.secondarySystemBackground
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
