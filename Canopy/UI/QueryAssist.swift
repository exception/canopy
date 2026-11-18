import AppKit
import SwiftUI

// MARK: - Field catalog

/// What the query bar knows about a collection's fields, sampled from the
/// documents it has shown. Feeds autocomplete and the preset menu.
struct FieldCatalog {
    var paths: [String] = []                 // dotted paths, document order
    var types: [String: String] = [:]        // path -> dominant type name
    var dates: [String] = []                 // paths holding dates
    var values: [String: [BValue]] = [:]     // low-cardinality scalar fields -> values by frequency

    var isEmpty: Bool { paths.isEmpty }

    static func build(_ docs: [BDoc]) -> FieldCatalog {
        var order: [String] = [], seen = Set<String>()
        var typeCounts: [String: [String: Int]] = [:]
        var valueCounts: [String: [BValue: Int]] = [:]
        var docsWith: [String: Int] = [:]

        func visit(_ d: BDoc, prefix: String, depth: Int, present: inout Set<String>) {
            for f in d.fields {
                let path = prefix.isEmpty ? f.key : prefix + "." + f.key
                if seen.insert(path).inserted { order.append(path) }
                present.insert(path)
                typeCounts[path, default: [:]][f.value.typeName, default: 0] += 1
                switch f.value {
                case .document(let sub) where depth < 3:
                    visit(sub, prefix: path, depth: depth + 1, present: &present)
                case .array(let items) where depth < 3:
                    for case .document(let sub) in items.prefix(20) { visit(sub, prefix: path, depth: depth + 1, present: &present) }
                case .string(let s) where s.count <= 40:
                    valueCounts[path, default: [:]][f.value, default: 0] += 1
                case .bool:
                    valueCounts[path, default: [:]][f.value, default: 0] += 1
                default: break
                }
            }
        }

        for d in docs.prefix(300) {
            var present = Set<String>()
            visit(d, prefix: "", depth: 0, present: &present)
            for p in present { docsWith[p, default: 0] += 1 }
        }

        var c = FieldCatalog()
        c.paths = order
        for (p, t) in typeCounts { c.types[p] = t.max { $0.value < $1.value }?.key }
        c.dates = order.filter { c.types[$0] == "Date" }
        for (p, counts) in valueCounts where p != "_id" {
            // Enum-like: few distinct values that repeat.
            let n = docsWith[p] ?? 0
            guard counts.count >= 1, counts.count <= 12, n >= 3, counts.count < n else { continue }
            c.values[p] = counts.sorted { $0.value != $1.value ? $0.value > $1.value : BFormat.preview($0.key) < BFormat.preview($1.key) }.map(\.key)
        }
        return c
    }

    /// Keeps what an earlier (perhaps broader) sample knew; a narrow filter
    /// shouldn't make fields or values disappear from suggestions.
    func merged(over old: FieldCatalog) -> FieldCatalog {
        var c = self
        for p in old.paths where c.types[p] == nil { c.paths.append(p); c.types[p] = old.types[p] }
        for p in old.dates where !c.dates.contains(p) { c.dates.append(p) }
        for (p, v) in old.values {
            var mergedValues = c.values[p] ?? []
            for x in v where !mergedValues.contains(x) { mergedValues.append(x) }
            c.values[p] = Array(mergedValues.prefix(16))
        }
        return c
    }
}

// MARK: - Presets

struct QueryPreset: Identifiable {
    var id: String { title + (filter ?? "") + (sort ?? "") + (window?.field ?? "") }
    var title: String
    var icon: String
    var filter: String? = nil
    var sort: String? = nil
    /// Time-window presets resolve their cutoff when applied, not when listed.
    var window: (field: String, span: TimeInterval)? = nil

    func resolved(now: Date = Date()) -> QueryPreset {
        guard let w = window else { return self }
        var p = self
        let since = ISO8601DateFormatter.mongo.string(from: now.addingTimeInterval(-w.span))
        p.filter = "{ \(QueryPresets.key(w.field)): { $gte: ISODate(\"\(since)\") } }"
        return p
    }
}

enum QueryPresets {
    static func sorts(_ c: FieldCatalog) -> [QueryPreset] {
        var out = [
            QueryPreset(title: "Newest", icon: "arrow.down", sort: "{ _id: -1 }"),
            QueryPreset(title: "Oldest", icon: "arrow.up", sort: "{ _id: 1 }"),
        ]
        for d in preferredDates(c).prefix(3) {
            out.append(QueryPreset(title: "\(d) ↓", icon: "calendar", sort: "{ \(key(d)): -1 }"))
            out.append(QueryPreset(title: "\(d) ↑", icon: "calendar", sort: "{ \(key(d)): 1 }"))
        }
        return out
    }

    /// Time-window filters for the main date field, computed when chosen.
    static func recent(_ c: FieldCatalog) -> [QueryPreset] {
        guard let d = preferredDates(c).first else { return [] }
        let windows: [(String, TimeInterval)] = [("Last hour", 3600), ("24 hours", 86400), ("7 days", 7 * 86400), ("30 days", 30 * 86400), ("90 days", 90 * 86400)]
        return windows.map { title, span in
            QueryPreset(title: title, icon: "clock", window: (d, span))
        }
    }

    /// One submenu per enum-like field: `status = "refunded"` and friends.
    static func values(_ c: FieldCatalog) -> [(field: String, presets: [QueryPreset])] {
        c.paths.compactMap { p in
            guard let vs = c.values[p], vs.count >= 2 else { return nil }
            return (p, vs.prefix(10).map { v in
                QueryPreset(title: BFormat.text(v, pretty: false), icon: "line.3.horizontal.decrease", filter: "{ \(key(p)): \(BFormat.text(v, pretty: false)) }")
            })
        }
        .prefix(8).map { $0 }
    }

    private static func preferredDates(_ c: FieldCatalog) -> [String] {
        let rank = ["createdAt", "created_at", "created", "timestamp", "date", "updatedAt", "updated_at"]
        return c.dates.sorted { a, b in
            let ra = rank.firstIndex(of: a) ?? (a.contains(".") ? 200 : 100), rb = rank.firstIndex(of: b) ?? (b.contains(".") ? 200 : 100)
            return ra < rb
        }
    }

    static func key(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" || $0 == "." } ? path : "\"\(path)\""
    }
}

extension ISO8601DateFormatter {
    static let mongo: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// MARK: - Completion engine

struct Suggestion: Hashable {
    var label: String
    var insert: String
    var detail: String
    /// Where the caret lands, counted back from the end of `insert`: 2 puts it
    /// between the quotes of `ObjectId("")`.
    var caretBack: Int = 0
}

struct CompletionResult {
    var range: NSRange          // text to replace (UTF-16)
    var items: [Suggestion]
}

enum QueryCompletion {
    static let operators: [(String, String)] = [
        ("$eq", "equals"), ("$ne", "not equal"), ("$gt", "greater than"), ("$gte", "greater or equal"),
        ("$lt", "less than"), ("$lte", "less or equal"), ("$in", "in array"), ("$nin", "not in array"),
        ("$exists", "field present"), ("$regex", "pattern"), ("$options", "regex flags"), ("$and", "all of"), ("$or", "any of"),
        ("$nor", "none of"), ("$not", "negate"), ("$elemMatch", "array element"), ("$size", "array length"),
        ("$all", "contains all"), ("$type", "BSON type"), ("$expr", "expression"), ("$text", "text search"),
        ("$search", "text query"), ("$near", "geo near"), ("$geoWithin", "geo within"), ("$mod", "modulo"),
    ]

    /// Shell constructors offered where a value goes. `caretBack` lands the caret inside.
    static let constructors: [(name: String, insert: String, caretBack: Int, type: String)] = [
        ("ObjectId", "ObjectId(\"\")", 2, "ObjectId"),
        ("ISODate", "ISODate(\"\")", 2, "Date"),
        ("NumberLong", "NumberLong()", 1, "Int64"),
        ("NumberInt", "NumberInt()", 1, "Int32"),
        ("NumberDecimal", "NumberDecimal(\"\")", 2, "Decimal128"),
        ("UUID", "UUID(\"\")", 2, "UUID"),
        ("RegExp", "RegExp(\"\")", 2, "RegExp"),
        ("Timestamp", "Timestamp()", 1, "Timestamp"),
        ("BinData", "BinData(0, \"\")", 2, "Binary"),
    ]
    static let literals = ["true", "false", "null"]

    private static func isWord(_ c: unichar) -> Bool {
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 46 || c == 36
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }

    /// Suggestions for the word ending at `cursor`, or nil when nothing fits.
    /// `operators` is off for sort and projection fields.
    static func complete(_ text: String, cursor: Int, catalog: FieldCatalog, operators allowOps: Bool) -> CompletionResult? {
        let s = text as NSString
        guard cursor <= s.length else { return nil }
        var start = cursor
        while start > 0, isWord(s.character(at: start - 1)) { start -= 1 }
        let token = s.substring(with: NSRange(location: start, length: cursor - start))

        var j = start
        var quote: unichar? = nil
        if j > 0, s.character(at: j - 1) == 34 || s.character(at: j - 1) == 39 { quote = s.character(at: j - 1); j -= 1 }
        var k = j
        while k > 0, isSpace(s.character(at: k - 1)) { k -= 1 }
        let prev: unichar? = k > 0 ? s.character(at: k - 1) : nil

        // Key position: right after `{`, `,` (inside an object) or at the start.
        if prev == nil || prev == 123 || (prev == 44 && innermostOpen(s, before: k - 1) == 123) {
            guard !token.isEmpty else { return nil }
            var items: [Suggestion] = []
            if token.hasPrefix("$") {
                guard allowOps, quote == nil else { return nil }
                items = operators.filter { $0.0.lowercased().hasPrefix(token.lowercased()) && $0.0 != token }
                    .map { Suggestion(label: $0.0, insert: $0.0 + ": ", detail: $0.1) }
            } else {
                items = rank(catalog.paths, token).map { p in
                    let k = quote == nil ? QueryPresets.key(p) : p
                    return Suggestion(label: p, insert: quote == nil ? k + ": " : k, detail: catalog.types[p] ?? "")
                }
            }
            if items.count == 1, items[0].label == token { return nil }
            return items.isEmpty ? nil : CompletionResult(range: NSRange(location: start, length: cursor - start), items: Array(items.prefix(40)))
        }

        // Value position: `field: |`, or an item in `[ … ]`.
        let inArray = prev == 91 || (prev == 44 && innermostOpen(s, before: k - 1) == 91)
        guard prev == 58 || inArray else { return nil }
        let field = prev == 58 ? keyBefore(s, colon: k - 1) : nil
        var items: [Suggestion] = []
        // Values seen for that field.
        if let field, let values = catalog.values[field] {
            items = values.compactMap { v in
                let lit = BFormat.text(v, pretty: false)
                if let raw = v.stringValue {
                    guard raw.lowercased().hasPrefix(token.lowercased()), raw != token else { return nil }
                    return Suggestion(label: lit, insert: quote == nil ? lit : raw, detail: field)
                }
                guard quote == nil, lit.hasPrefix(token.lowercased()), lit != token else { return nil }
                return Suggestion(label: lit, insert: lit, detail: field)
            }
        }
        if quote == nil {
            items += constructorSuggestions(token, fieldType: field.flatMap { catalog.types[$0] })
        }
        return items.isEmpty ? nil : CompletionResult(range: NSRange(location: start, length: cursor - start), items: items)
    }

    /// `Obje` -> `ObjectId("")`. With nothing typed yet, only the constructor that matches
    /// the field's type is offered (`_id: ` -> `ObjectId("")`), so the popup stays quiet otherwise.
    private static func constructorSuggestions(_ token: String, fieldType: String?) -> [Suggestion] {
        let t = token.lowercased()
        if t.isEmpty {
            return constructors.filter { $0.type == fieldType }.map {
                Suggestion(label: $0.insert, insert: $0.insert, detail: fieldType ?? "", caretBack: $0.caretBack)
            }
        }
        // Matching the field's type first, then list order.
        let ctor = constructors.filter { $0.name.lowercased().hasPrefix(t) }
            .sorted { ($0.type == fieldType ? 0 : 1) < ($1.type == fieldType ? 0 : 1) }
            .map { Suggestion(label: $0.insert, insert: $0.insert, detail: $0.type, caretBack: $0.caretBack) }
        let lits = literals.filter { $0.hasPrefix(t) && $0 != t }.map { Suggestion(label: $0, insert: $0, detail: "") }
        return ctor + lits
    }

    /// Prefix matches first (shallow before deep), then matches on a path segment, then substring.
    static func rank(_ paths: [String], _ token: String) -> [String] {
        let t = token.lowercased()
        var scored: [(Int, Int, String)] = []
        for (i, p) in paths.enumerated() {
            let l = p.lowercased()
            let score: Int
            if l.hasPrefix(t) { score = 0 }
            else if l.split(separator: ".").contains(where: { $0.hasPrefix(t) }) { score = 1 }
            else if t.count >= 2, l.contains(t) { score = 2 }
            else { continue }
            scored.append((score * 1000 + p.filter { $0 == "." }.count * 100, i, p))
        }
        return scored.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// The bracket (`{` or `[`) that encloses position `i`, skipping strings.
    private static func innermostOpen(_ s: NSString, before i: Int) -> unichar? {
        var depth = 0, k = i - 1
        while k >= 0 {
            let c = s.character(at: k)
            if c == 125 || c == 93 { depth += 1 }
            else if c == 123 || c == 91 { if depth == 0 { return c }; depth -= 1 }
            k -= 1
        }
        return nil
    }

    private static func keyBefore(_ s: NSString, colon: Int) -> String? {
        var e = colon
        while e > 0, isSpace(s.character(at: e - 1)) { e -= 1 }
        var quoted = false
        if e > 0, s.character(at: e - 1) == 34 || s.character(at: e - 1) == 39 { quoted = true; e -= 1 }
        var b = e
        if quoted {
            while b > 0, s.character(at: b - 1) != 34, s.character(at: b - 1) != 39 { b -= 1 }
        } else {
            while b > 0, isWord(s.character(at: b - 1)) { b -= 1 }
        }
        guard b < e else { return nil }
        return s.substring(with: NSRange(location: b, length: e - b))
    }
}

// MARK: - Completion popup

@MainActor @Observable
final class CompletionModel {
    var items: [Suggestion] = []
    var selected = 0
    var onPick: (Int) -> Void = { _ in }
}

private final class CompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A small suggestion list that floats under the caret of a text view
/// without taking keyboard focus from it.
@MainActor
final class CompletionPopup {
    let model = CompletionModel()
    private var panel: NSPanel?
    private(set) var range = NSRange(location: NSNotFound, length: 0)
    var isVisible: Bool { panel?.isVisible ?? false }

    static let rowHeight: CGFloat = 24

    func show(_ r: CompletionResult, in tv: NSTextView) {
        guard let window = tv.window else { return }
        range = r.range
        if model.items != r.items { model.selected = 0 }
        model.items = r.items
        let p = panel ?? makePanel()
        let rows = min(r.items.count, 8)
        let width = min(max(CGFloat(r.items.map { $0.label.count + $0.detail.count }.max() ?? 20) * 7.4 + 48, 220), 420)
        let height = CGFloat(rows) * Self.rowHeight + 8
        var caret = tv.firstRect(forCharacterRange: NSRange(location: r.range.location, length: 0), actualRange: nil)
        if caret == .zero { caret = window.convertToScreen(tv.convert(tv.bounds, to: nil)) }
        var origin = NSPoint(x: caret.minX - 8, y: caret.minY - height - 6)
        if let screen = window.screen?.visibleFrame, origin.y < screen.minY { origin.y = caret.maxY + 6 }
        p.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if p.parent == nil { window.addChildWindow(p, ordered: .above) }
        p.orderFront(nil)
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        range = NSRange(location: NSNotFound, length: 0)
    }

    func move(_ d: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + d + model.items.count) % model.items.count
    }

    private func makePanel() -> NSPanel {
        let p = CompletionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = true
        p.contentView = FirstMouseHostingView(rootView: CompletionList(model: model))
        panel = p
        return p
    }
}

private struct CompletionList: View {
    @Bindable var model: CompletionModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.offset) { i, item in
                        HStack(spacing: 8) {
                            Text(item.label).font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(i == model.selected ? Color.cText : Color.cText2).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(item.detail).font(.system(size: 10.5)).foregroundStyle(Color.cText3).lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: CompletionPopup.rowHeight)
                        .background(i == model.selected ? Color.cAccent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { model.onPick(i) }
                        .id(i)
                    }
                }
                .padding(4)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selected) { _, s in proxy.scrollTo(s) }
        }
        .background(Color.cRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.cHairline))
    }
}
