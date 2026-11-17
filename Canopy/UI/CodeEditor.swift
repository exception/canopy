import AppKit
import SwiftUI

/// A syntax-highlighted mongosh/JSON editor backed by NSTextView.
/// `singleLine` fields submit on Return (⇧Return inserts a newline).
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var singleLine = false
    var editable = true
    var fontSize: CGFloat = 12.5
    var focusOnAppear = false
    var onSubmit: (() -> Void)? = nil
    var onHeight: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = !singleLine
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let tv = CodeTextView()
        tv.coordinator = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isEditable = editable
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 2, height: singleLine ? 4 : 6)
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.insertionPointColor = Theme.accent
        tv.placeholder = placeholder
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 4
        tv.delegate = context.coordinator
        tv.selectedTextAttributes = [.backgroundColor: Theme.selection]
        scroll.documentView = tv
        context.coordinator.textView = tv
        context.coordinator.apply(text)
        if focusOnAppear { DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) } }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = context.coordinator.textView else { return }
        tv.isEditable = editable
        tv.placeholder = placeholder
        if tv.string != text { context.coordinator.apply(text) } else { context.coordinator.reportHeight() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: CodeTextView?
        private var applying = false

        init(_ p: CodeEditor) { parent = p }

        func apply(_ s: String) {
            guard let tv = textView else { return }
            applying = true
            let sel = tv.selectedRanges
            tv.textStorage?.setAttributedString(Highlighter.highlight(s, font: .monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)))
            let len = (s as NSString).length
            tv.selectedRanges = sel.map { r in NSValue(range: NSRange(location: min(r.rangeValue.location, len), length: 0)) }
            applying = false
            tv.needsDisplay = true
            reportHeight()
        }

        func reportHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer, let cb = parent.onHeight else { return }
            lm.ensureLayout(for: tc)
            let h = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            DispatchQueue.main.async { cb(h) }
        }

        func textDidChange(_ n: Notification) {
            guard !applying, let tv = textView else { return }
            parent.text = tv.string
            // Re-color in place without disturbing the cursor.
            let hl = Highlighter.highlight(tv.string, font: .monospacedSystemFont(ofSize: parent.fontSize, weight: .regular))
            tv.textStorage?.beginEditing()
            hl.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: hl.length)) { v, r, _ in
                if let c = v { tv.textStorage?.addAttribute(.foregroundColor, value: c, range: r) }
            }
            tv.textStorage?.endEditing()
            reportHeight()
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) {
                let flags = NSApp.currentEvent?.modifierFlags ?? []
                if flags.contains(.command) || (parent.singleLine && !flags.contains(.shift)) {
                    parent.onSubmit?()
                    return true
                }
                // Keep indentation.
                let s = tv.string as NSString
                let loc = tv.selectedRange().location
                let lineStart = s.lineRange(for: NSRange(location: loc, length: 0)).location
                var indent = ""
                var k = lineStart
                while k < s.length, s.character(at: k) == 32 { indent += " "; k += 1 }
                if loc > 0, ["{", "["].contains(s.substring(with: NSRange(location: loc - 1, length: 1))) { indent += "  " }
                tv.insertText("\n" + indent, replacementRange: tv.selectedRange())
                return true
            }
            if sel == #selector(NSResponder.insertTab(_:)) {
                if parent.singleLine { tv.window?.selectNextKeyView(nil); return true }
                tv.insertText("  ", replacementRange: tv.selectedRange())
                return true
            }
            return false
        }

        func textView(_ tv: NSTextView, shouldChangeTextIn range: NSRange, replacementString s: String?) -> Bool {
            // Auto-close brackets and quotes.
            guard let s, s.count == 1, range.length == 0 else { return true }
            let pairs: [String: String] = ["{": "}", "[": "]", "(": ")", "\"": "\""]
            let str = tv.string as NSString
            let next = range.location < str.length ? str.substring(with: NSRange(location: range.location, length: 1)) : ""
            if ["}", "]", ")", "\""].contains(s), next == s {
                tv.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return false
            }
            if let close = pairs[s], next.isEmpty || next == " " || next == "}" || next == "]" || next == "," || next == "\n" {
                if s == "\"", range.location > 0, str.substring(with: NSRange(location: range.location - 1, length: 1)).rangeOfCharacter(from: .alphanumerics) != nil { return true }
                tv.insertText(s + close, replacementRange: range)
                tv.setSelectedRange(NSRange(location: range.location + 1, length: 0))
                return false
            }
            return true
        }
    }
}

final class CodeTextView: NSTextView {
    weak var coordinator: CodeEditor.Coordinator?
    var placeholder = "" { didSet { needsDisplay = true } }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        if string.isEmpty, !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: Theme.text3]
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 4, y: textContainerInset.height), withAttributes: attrs)
        }
    }
}

/// Read-only highlighted text that can be long (JSON view, raw explain).
struct CodeView: NSViewRepresentable {
    var text: String
    var fontSize: CGFloat = 12.5

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 14, height: 12)
        tv.selectedTextAttributes = [.backgroundColor: Theme.selection]
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let tv = scroll.documentView as! NSTextView
        if context.coordinator.last != text {
            context.coordinator.last = text
            tv.textStorage?.setAttributedString(Highlighter.highlight(text, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular)))
        }
    }

    func makeCoordinator() -> Box { Box() }
    final class Box { var last: String? }
}
