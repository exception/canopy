import Foundation

/// Guesses which collection an ObjectId field points at from its name:
/// `dealership`, `dealershipId`, `dealership_id` and `dealership_ids` all link to
/// `dealerships`; `seller_dealership_id` falls back to `dealerships` too.
struct ReferenceLinker {
    let db: String
    let collections: [String]

    /// The collection `key` refers to, or nil when no name fits.
    func target(forKey key: String) -> String? {
        let words = Self.words(Self.stripIDSuffix(key))
        guard !words.isEmpty else { return nil }
        let names = Dictionary(collections.map { (Self.words($0).joined(), $0) }, uniquingKeysWith: { a, _ in a })
        // Whole name first, then drop leading qualifiers: seller_dealership -> dealership.
        for start in words.indices {
            let base = words[start...].joined()
            for candidate in Self.forms(base) { if let hit = names[candidate] { return hit } }
        }
        return nil
    }

    /// A filter that opens the referenced document(s).
    static func filter(for value: BValue) -> String? {
        switch value {
        case .objectId(let hex): return "{ _id: ObjectId(\"\(hex)\") }"
        case .array(let items):
            let ids = items.compactMap { v -> String? in if case .objectId(let h) = v { return "ObjectId(\"\(h)\")" }; return nil }
            guard !ids.isEmpty, ids.count == items.count else { return nil }
            return ids.count == 1 ? "{ _id: \(ids[0]) }" : "{ _id: { $in: [\(ids.joined(separator: ", "))] } }"
        default: return nil
        }
    }

    static func isReference(_ value: BValue) -> Bool { filter(for: value) != nil }

    // MARK: Name handling

    private static func stripIDSuffix(_ key: String) -> String {
        for suffix in ["_ids", "_id", "Ids", "IDs", "Id", "ID", "_ref", "Ref"] where key.count > suffix.count && key.hasSuffix(suffix) {
            return String(key.dropLast(suffix.count))
        }
        return key
    }

    /// Lowercased words from snake, kebab, dotted or camel case.
    static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        var prevLower = false
        for ch in s {
            if ch == "_" || ch == "-" || ch == "." || ch == " " {
                if !cur.isEmpty { out.append(cur) }
                cur = ""; prevLower = false
                continue
            }
            if ch.isUppercase, prevLower, !cur.isEmpty { out.append(cur); cur = "" }
            cur.append(Character(ch.lowercased()))
            prevLower = ch.isLowercase || ch.isNumber
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Singular and plural spellings to look for.
    private static func forms(_ base: String) -> [String] {
        var f = [base, base + "s", base + "es"]
        if base.hasSuffix("y") { f.append(String(base.dropLast()) + "ies") }
        if base.hasSuffix("s") { f.append(String(base.dropLast())) }
        if base.hasSuffix("ies") { f.append(String(base.dropLast(3)) + "y") }
        if base == "person" { f.append("people") }
        return f
    }
}
