import AppKit
import Foundation

/// Renders values as mongosh-style text (what people paste back into a query
/// box) or as relaxed Extended JSON (what other tools and Claude read).
enum BFormat {
    enum Style { case shell, ejson }

    static func text(_ v: BValue, style: Style = .shell, pretty: Bool = true, indent: String = "  ") -> String {
        var out = ""
        write(v, style: style, pretty: pretty, indent: indent, level: 0, into: &out)
        return out
    }

    static func text(_ d: BDoc, style: Style = .shell, pretty: Bool = true) -> String {
        text(.document(d), style: style, pretty: pretty)
    }

    /// Short single-line preview for table cells.
    static func preview(_ v: BValue, max: Int = 120) -> String {
        switch v {
        case .document(let d): return d.isEmpty ? "{}" : "{ \(d.count) field\(d.count == 1 ? "" : "s") }"
        case .array(let a): return a.isEmpty ? "[]" : "[ \(a.count) item\(a.count == 1 ? "" : "s") ]"
        case .string(let s):
            let one = s.replacingOccurrences(of: "\n", with: "⏎ ")
            return one.count > max ? String(one.prefix(max)) + "…" : one
        case .date(let d): return DateParsing.format(d)
        case .objectId(let h): return h
        case .decimal(let s): return s
        case .int64(let i): return String(i)
        case .binary(4, let data): return uuidString(data)
        default: return text(v, pretty: false)
        }
    }

    static func isIdentifier(_ k: String) -> Bool {
        guard let f = k.unicodeScalars.first, !k.isEmpty else { return false }
        if CharacterSet.decimalDigits.contains(f) { return false }
        return k.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "$" } && k.unicodeScalars.allSatisfy { $0.isASCII }
    }

    static func quote(_ s: String) -> String {
        var o = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            default:
                if c.value < 0x20 { o += String(format: "\\u%04x", c.value) } else { o.unicodeScalars.append(c) }
            }
        }
        return o + "\""
    }

    static func uuidString(_ d: Data) -> String {
        let h = d.hex
        guard h.count == 32 else { return h }
        let a = Array(h)
        let parts: [String] = [String(a[0..<8]), String(a[8..<12]), String(a[12..<16]), String(a[16..<20]), String(a[20..<32])]
        return parts.joined(separator: "-")
    }

    static func number(_ d: Double) -> String {
        if d.isNaN { return "NaN" }
        if d.isInfinite { return d < 0 ? "-Infinity" : "Infinity" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    private static func write(_ v: BValue, style: Style, pretty: Bool, indent: String, level: Int, into o: inout String) {
        let nl = pretty ? "\n" : ""
        let pad = pretty ? String(repeating: indent, count: level + 1) : ""
        let closePad = pretty ? String(repeating: indent, count: level) : ""
        switch v {
        case .document(let d):
            if d.isEmpty { o += "{}"; return }
            o += "{" + (pretty ? nl : " ")
            for (n, f) in d.fields.enumerated() {
                o += pad
                o += (style == .shell && isIdentifier(f.key)) ? f.key : quote(f.key)
                o += ": "
                write(f.value, style: style, pretty: pretty, indent: indent, level: level + 1, into: &o)
                if n < d.count - 1 { o += "," }
                o += pretty ? nl : " "
            }
            o += closePad + "}"
        case .array(let a):
            if a.isEmpty { o += "[]"; return }
            // Short arrays of scalars stay on one line.
            let scalars = a.allSatisfy { !$0.isContainer }
            if pretty && scalars && a.count <= 8 {
                o += "["
                for (n, e) in a.enumerated() { write(e, style: style, pretty: false, indent: indent, level: 0, into: &o); if n < a.count - 1 { o += ", " } }
                o += "]"
                return
            }
            o += "[" + nl
            for (n, e) in a.enumerated() {
                o += pad
                write(e, style: style, pretty: pretty, indent: indent, level: level + 1, into: &o)
                if n < a.count - 1 { o += "," + (pretty ? "" : " ") }
                o += nl
            }
            o += closePad + "]"
        case .string(let s): o += quote(s)
        case .double(let d):
            if style == .ejson && (d.isNaN || d.isInfinite) { o += "{\"$numberDouble\": \"\(number(d))\"}" }
            else { o += number(d) }
        case .int32(let i): o += String(i)
        case .int64(let i): o += style == .shell ? "Long(\"\(i)\")" : String(i)
        case .decimal(let s): o += style == .shell ? "Decimal128(\"\(s)\")" : "{\"$numberDecimal\": \"\(s)\"}"
        case .objectId(let h): o += style == .shell ? "ObjectId(\"\(h)\")" : "{\"$oid\": \"\(h)\"}"
        case .bool(let b): o += b ? "true" : "false"
        case .date(let d): o += style == .shell ? "ISODate(\"\(DateParsing.format(d))\")" : "{\"$date\": \"\(DateParsing.format(d))\"}"
        case .null: o += "null"
        case .undefined: o += style == .shell ? "undefined" : "null"
        case .regex(let p, let f):
            o += style == .shell ? "/\(p)/\(f)" : "{\"$regularExpression\": {\"pattern\": \(quote(p)), \"options\": \"\(f)\"}}"
        case .javascript(let c): o += style == .shell ? "Code(\(quote(c)))" : "{\"$code\": \(quote(c))}"
        case .timestamp(let t, let i): o += style == .shell ? "Timestamp({ t: \(t), i: \(i) })" : "{\"$timestamp\": {\"t\": \(t), \"i\": \(i)}}"
        case .binary(let sub, let data):
            if sub == 4 && data.count == 16 { o += style == .shell ? "UUID(\"\(uuidString(data))\")" : "{\"$uuid\": \"\(uuidString(data))\"}" }
            else if style == .shell { o += "BinData(\(sub), \"\(data.base64EncodedString())\")" }
            else { o += "{\"$binary\": {\"base64\": \"\(data.base64EncodedString())\", \"subType\": \"\(String(format: "%02x", sub))\"}}" }
        case .minKey: o += style == .shell ? "MinKey()" : "{\"$minKey\": 1}"
        case .maxKey: o += style == .shell ? "MaxKey()" : "{\"$maxKey\": 1}"
        }
    }
}

// MARK: - Syntax highlighting

enum Highlighter {
    struct Palette {
        var key, string, number, keyword, type, punct, comment, plain, op: NSColor
    }

    static var palette: Palette {
        Palette(key: Theme.synKey, string: Theme.synString, number: Theme.synNumber, keyword: Theme.synKeyword,
                type: Theme.synType, punct: Theme.text3, comment: Theme.text3, plain: Theme.text, op: Theme.synOperator)
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    /// Tokenizes shell-ish JSON text and colors it. Tolerant: it never fails,
    /// so it can color text while the user is mid-edit.
    static func highlight(_ text: String, font: NSFont = font) -> NSAttributedString {
        let p = palette
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: p.plain])
        let ns = text as NSString
        let len = ns.length
        var i = 0
        func color(_ r: NSRange, _ c: NSColor) { out.addAttribute(.foregroundColor, value: c, range: r) }
        func ch(_ k: Int) -> unichar { k < len ? ns.character(at: k) : 0 }
        func isIdent(_ c: unichar) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 || c == 36 || c == 46 || c > 127 }
        while i < len {
            let c = ch(i)
            if c == 47, ch(i + 1) == 47 { // comment
                let start = i
                while i < len && ch(i) != 10 { i += 1 }
                color(NSRange(location: start, length: i - start), p.comment)
                continue
            }
            if c == 34 || c == 39 { // string
                let start = i, q = c
                i += 1
                while i < len && ch(i) != q { if ch(i) == 92 { i += 1 }; i += 1 }
                i = min(i + 1, len)
                var j = i
                while j < len && (ch(j) == 32) { j += 1 }
                let isKey = ch(j) == 58
                color(NSRange(location: start, length: i - start), isKey ? p.key : p.string)
                continue
            }
            if (c >= 48 && c <= 57) || (c == 45 && ch(i + 1) >= 48 && ch(i + 1) <= 57) {
                let start = i
                i += 1
                while i < len && ((ch(i) >= 48 && ch(i) <= 57) || ch(i) == 46 || ch(i) == 101 || ch(i) == 69) { i += 1 }
                color(NSRange(location: start, length: i - start), p.number)
                continue
            }
            if isIdent(c) {
                let start = i
                while i < len && isIdent(ch(i)) { i += 1 }
                let word = ns.substring(with: NSRange(location: start, length: i - start))
                var j = i
                while j < len && ch(j) == 32 { j += 1 }
                let r = NSRange(location: start, length: i - start)
                if ch(j) == 58 { color(r, word.hasPrefix("$") ? p.op : p.key) }
                else if ch(j) == 40 { color(r, p.type) }
                else if ["true", "false", "null", "undefined", "new", "NaN", "Infinity"].contains(word) { color(r, p.keyword) }
                else if word.hasPrefix("$") { color(r, p.op) }
                continue
            }
            if "{}[]:,()".utf16.contains(c) { color(NSRange(location: i, length: 1), p.punct) }
            i += 1
        }
        return out
    }
}
