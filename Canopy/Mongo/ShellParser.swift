import Foundation

struct ParseError: Error, LocalizedError {
    var message: String
    var offset: Int
    var errorDescription: String? { message }
}

/// Parses what people actually type into a Mongo query box: JSON, Extended
/// JSON and mongosh syntax (unquoted keys, single quotes, trailing commas,
/// comments, `ObjectId("…")`, `ISODate("…")`, `new Date()`, `/re/i`, …).
struct ShellParser {
    private let s: [UInt8]
    private var i = 0

    static func parse(_ text: String) throws -> BValue {
        var p = ShellParser(Array(text.utf8))
        p.skip()
        if p.i >= p.s.count { return .document(BDoc()) }
        let v = try p.value()
        p.skip()
        if p.i < p.s.count { throw p.err("Unexpected '\(p.ch)' after value") }
        return EJSON.unwrap(v)
    }

    /// Empty text is `{}`; anything else must be an object.
    static func parseDocument(_ text: String) throws -> BDoc {
        let v = try parse(text)
        guard case .document(let d) = v else { throw ParseError(message: "Expected an object { … }", offset: 0) }
        return d
    }

    static func parseArray(_ text: String) throws -> [BValue] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return [] }
        let v = try parse(t)
        if case .array(let a) = v { return a }
        if case .document = v { return [v] }
        throw ParseError(message: "Expected an array [ … ]", offset: 0)
    }

    private init(_ s: [UInt8]) { self.s = s }

    private var ch: Character { i < s.count ? Character(UnicodeScalar(s[i])) : "\0" }

    private func err(_ m: String) -> ParseError {
        // Report line:col for humans.
        var line = 1, col = 1
        for k in 0..<min(i, s.count) { if s[k] == 10 { line += 1; col = 1 } else { col += 1 } }
        return ParseError(message: "\(m) (line \(line), col \(col))", offset: i)
    }

    private mutating func skip() {
        while i < s.count {
            let c = s[i]
            if c == 32 || c == 9 || c == 10 || c == 13 { i += 1; continue }
            if c == 47, i + 1 < s.count, s[i + 1] == 47 { // //
                while i < s.count && s[i] != 10 { i += 1 }
                continue
            }
            if c == 47, i + 1 < s.count, s[i + 1] == 42 { // /*
                i += 2
                while i + 1 < s.count && !(s[i] == 42 && s[i + 1] == 47) { i += 1 }
                i = min(i + 2, s.count)
                continue
            }
            break
        }
    }

    private mutating func expect(_ c: UInt8) throws {
        skip()
        guard i < s.count, s[i] == c else { throw err("Expected '\(Character(UnicodeScalar(c)))'") }
        i += 1
    }

    private mutating func value() throws -> BValue {
        skip()
        guard i < s.count else { throw err("Unexpected end of input") }
        let c = s[i]
        switch c {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""), UInt8(ascii: "'"): return .string(try string())
        case UInt8(ascii: "/"): return try regex()
        case UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try number()
        default:
            if isIdentStart(c) { return try identifierValue() }
            throw err("Unexpected '\(ch)'")
        }
    }

    private mutating func object() throws -> BValue {
        try expect(UInt8(ascii: "{"))
        var d = BDoc()
        skip()
        if i < s.count, s[i] == UInt8(ascii: "}") { i += 1; return .document(d) }
        while true {
            skip()
            let key: String
            guard i < s.count else { throw err("Unterminated object") }
            if s[i] == UInt8(ascii: "\"") || s[i] == UInt8(ascii: "'") { key = try string() }
            else if isIdentStart(s[i]) || s[i] == UInt8(ascii: "$") || isDigit(s[i]) { key = identifier(allowDots: true) }
            else { throw err("Expected a field name") }
            try expect(UInt8(ascii: ":"))
            let v = try value()
            d.fields.append(BField(key: key, value: v))
            skip()
            guard i < s.count else { throw err("Unterminated object, expected '}'") }
            if s[i] == UInt8(ascii: ",") {
                i += 1; skip()
                if i < s.count, s[i] == UInt8(ascii: "}") { i += 1; return .document(d) }
                continue
            }
            if s[i] == UInt8(ascii: "}") { i += 1; return .document(d) }
            throw err("Expected ',' or '}'")
        }
    }

    private mutating func array() throws -> BValue {
        try expect(UInt8(ascii: "["))
        var a: [BValue] = []
        skip()
        if i < s.count, s[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
        while true {
            a.append(try value())
            skip()
            guard i < s.count else { throw err("Unterminated array, expected ']'") }
            if s[i] == UInt8(ascii: ",") {
                i += 1; skip()
                if i < s.count, s[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                continue
            }
            if s[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
            throw err("Expected ',' or ']'")
        }
    }

    private mutating func string() throws -> String {
        let q = s[i]
        i += 1
        var bytes: [UInt8] = []
        while i < s.count {
            let c = s[i]
            if c == q { i += 1; return String(decoding: bytes, as: UTF8.self) }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < s.count else { break }
                let e = s[i]
                switch e {
                case UInt8(ascii: "n"): bytes.append(10)
                case UInt8(ascii: "t"): bytes.append(9)
                case UInt8(ascii: "r"): bytes.append(13)
                case UInt8(ascii: "b"): bytes.append(8)
                case UInt8(ascii: "f"): bytes.append(12)
                case UInt8(ascii: "u"):
                    guard i + 4 < s.count, let code = UInt32(String(decoding: s[(i + 1)...(i + 4)], as: UTF8.self), radix: 16) else { throw err("Bad \\u escape") }
                    i += 4
                    var scalarCode = code
                    // Surrogate pair
                    if (0xD800...0xDBFF).contains(code), i + 6 < s.count, s[i + 1] == UInt8(ascii: "\\"), s[i + 2] == UInt8(ascii: "u"),
                       let lo = UInt32(String(decoding: s[(i + 3)...(i + 6)], as: UTF8.self), radix: 16), (0xDC00...0xDFFF).contains(lo) {
                        scalarCode = 0x10000 + ((code - 0xD800) << 10) + (lo - 0xDC00)
                        i += 6
                    }
                    if let u = UnicodeScalar(scalarCode) { bytes.append(contentsOf: Array(String(Character(u)).utf8)) }
                default: bytes.append(e)
                }
                i += 1
                continue
            }
            bytes.append(c)
            i += 1
        }
        throw err("Unterminated string")
    }

    private mutating func regex() throws -> BValue {
        i += 1
        var bytes: [UInt8] = []
        var inClass = false
        while i < s.count {
            let c = s[i]
            if c == UInt8(ascii: "\\"), i + 1 < s.count { bytes.append(c); bytes.append(s[i + 1]); i += 2; continue }
            if c == UInt8(ascii: "[") { inClass = true }
            if c == UInt8(ascii: "]") { inClass = false }
            if c == UInt8(ascii: "/") && !inClass { break }
            bytes.append(c); i += 1
        }
        guard i < s.count else { throw err("Unterminated regex") }
        i += 1
        var flags = ""
        while i < s.count, isIdentStart(s[i]) { flags.append(Character(UnicodeScalar(s[i]))); i += 1 }
        return .regex(String(decoding: bytes, as: UTF8.self), flags)
    }

    private mutating func number() throws -> BValue {
        let start = i
        if s[i] == UInt8(ascii: "-") || s[i] == UInt8(ascii: "+") { i += 1 }
        // -Infinity
        if i < s.count, isIdentStart(s[i]) {
            let id = identifier(allowDots: false)
            let neg = s[start] == UInt8(ascii: "-")
            if id == "Infinity" { return .double(neg ? -.infinity : .infinity) }
            throw err("Unexpected '\(id)'")
        }
        var isFloat = false
        while i < s.count {
            let c = s[i]
            if isDigit(c) { i += 1; continue }
            if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") { isFloat = true; i += 1; continue }
            if (c == UInt8(ascii: "-") || c == UInt8(ascii: "+")), i > start, s[i - 1] == UInt8(ascii: "e") || s[i - 1] == UInt8(ascii: "E") { i += 1; continue }
            break
        }
        let text = String(decoding: s[start..<i], as: UTF8.self)
        if !isFloat, let v = Int64(text) {
            if let v32 = Int32(exactly: v) { return .int32(v32) }
            return .int64(v)
        }
        guard let d = Double(text) else { throw err("Bad number '\(text)'") }
        return .double(d)
    }

    private func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    private func isIdentStart(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c >= 0x80 }

    private mutating func identifier(allowDots: Bool) -> String {
        let start = i
        while i < s.count {
            let c = s[i]
            if isIdentStart(c) || isDigit(c) || (allowDots && c == UInt8(ascii: ".")) { i += 1 } else { break }
        }
        return String(decoding: s[start..<i], as: UTF8.self)
    }

    private mutating func args() throws -> [BValue] {
        try expect(UInt8(ascii: "("))
        var out: [BValue] = []
        skip()
        if i < s.count, s[i] == UInt8(ascii: ")") { i += 1; return out }
        while true {
            out.append(try value())
            skip()
            guard i < s.count else { throw err("Expected ')'") }
            if s[i] == UInt8(ascii: ",") { i += 1; continue }
            if s[i] == UInt8(ascii: ")") { i += 1; return out }
            throw err("Expected ',' or ')'")
        }
    }

    private mutating func identifierValue() throws -> BValue {
        var id = identifier(allowDots: false)
        if id == "new" { skip(); id = identifier(allowDots: false) }
        switch id {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        case "undefined": return .undefined
        case "NaN": return .double(.nan)
        case "Infinity": return .double(.infinity)
        default: break
        }
        skip()
        guard i < s.count, s[i] == UInt8(ascii: "(") else { throw err("Unknown identifier '\(id)'") }
        let a = try args()
        let str = a.first?.stringValue
        switch id {
        case "ObjectId", "ObjectID":
            guard let h = str else { return .objectId(Self.newObjectIdHex()) }
            guard h.count == 24, h.allSatisfy(\.isHexDigit) else { throw err("ObjectId needs 24 hex characters") }
            return .objectId(h.lowercased())
        case "ISODate", "Date":
            if a.isEmpty { return .date(Date()) }
            if let str {
                guard let d = DateParsing.parse(str) else { throw err("Can't read date '\(str)'") }
                return .date(d)
            }
            if let n = a.first?.number { return .date(Date(timeIntervalSince1970: n / 1000)) }
            throw err("Bad date")
        case "NumberLong", "Long", "Int64":
            if let str, let v = Int64(str) { return .int64(v) }
            if let n = a.first?.number, let v = Int64(exactly: n.rounded(.towardZero)) { return .int64(v) }
            throw err("NumberLong out of range")
        case "NumberInt", "Int32":
            if let str, let v = Int32(str) { return .int32(v) }
            if let n = a.first?.number, let v = Int32(exactly: n.rounded(.towardZero)) { return .int32(v) }
            throw err("NumberInt out of range")
        case "Double":
            if let n = a.first?.number { return .double(n) }
            if let str, let v = Double(str) { return .double(v) }
            throw err("Bad Double")
        case "NumberDecimal", "Decimal128":
            let t = str ?? a.first?.number.map { String($0) } ?? ""
            guard Decimal128Codec.parts(t) != nil else { throw err("Bad decimal '\(t)'") }
            return .decimal(t)
        case "UUID":
            let hex = (str ?? UUID().uuidString).replacingOccurrences(of: "-", with: "")
            guard hex.count == 32, let data = Data(hex: hex) else { throw err("Bad UUID") }
            return .binary(4, data)
        case "BinData":
            guard a.count == 2, let n = a[0].number, let sub = UInt8(exactly: n), let b64 = a[1].stringValue, let data = Data(base64Encoded: b64) else { throw err("BinData(subtype 0-255, base64)") }
            return .binary(sub, data)
        case "Timestamp":
            if a.count == 2, let t = a[0].number.flatMap({ UInt32(exactly: $0) }), let inc = a[1].number.flatMap({ UInt32(exactly: $0) }) { return .timestamp(t, inc) }
            if let d = a.first?.doc, let t = d["t"]?.number.flatMap({ UInt32(exactly: $0) }), let inc = d["i"]?.number.flatMap({ UInt32(exactly: $0) }) { return .timestamp(t, inc) }
            if !a.isEmpty { throw err("Timestamp values must be 0…4294967295") }
            return .timestamp(UInt32(Date().timeIntervalSince1970), 0)
        case "RegExp":
            return .regex(str ?? "", a.count > 1 ? a[1].stringValue ?? "" : "")
        case "MinKey": return .minKey
        case "MaxKey": return .maxKey
        case "Code": return .javascript(str ?? "")
        default: throw err("Unknown function '\(id)()'")
        }
    }

    static func newObjectIdHex() -> String {
        let t = UInt32(Date().timeIntervalSince1970)
        var bytes = withUnsafeBytes(of: t.bigEndian, Array.init)
        for _ in 0..<8 { bytes.append(UInt8.random(in: 0...255)) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Canonical and relaxed Extended JSON wrappers -> real values.
enum EJSON {
    static func unwrap(_ v: BValue) -> BValue {
        switch v {
        case .array(let a): return .array(a.map(unwrap))
        case .document(let d):
            if d.count == 1 || d.count == 2, let k = d.fields.first?.key, k.hasPrefix("$"), let w = wrapper(d) { return w }
            return .document(BDoc(d.fields.map { BField(key: $0.key, value: unwrap($0.value)) }))
        default: return v
        }
    }

    private static func wrapper(_ d: BDoc) -> BValue? {
        let k = d.fields[0].key, v = d.fields[0].value
        if d.count == 2 { return nil } // e.g. {$regex, $options} is a query operator, not a wrapper
        switch k {
        case "$oid": if let s = v.stringValue, s.count == 24, s.allSatisfy(\.isHexDigit) { return .objectId(s.lowercased()) }
        case "$date":
            if let s = v.stringValue, let dt = DateParsing.parse(s) { return .date(dt) }
            if let n = v.number { return .date(Date(timeIntervalSince1970: n / 1000)) }
            if let inner = v.doc, let s = inner["$numberLong"]?.stringValue, let n = Double(s) { return .date(Date(timeIntervalSince1970: n / 1000)) }
        case "$numberLong": if let s = v.stringValue, let n = Int64(s) { return .int64(n) }
        case "$numberInt": if let s = v.stringValue, let n = Int32(s) { return .int32(n) }
        case "$numberDouble": if let s = v.stringValue, let n = Double(s) { return .double(n) }
        case "$numberDecimal": if let s = v.stringValue, Decimal128Codec.parts(s) != nil { return .decimal(s) }
        case "$uuid": if let s = v.stringValue, let data = Data(hex: s.replacingOccurrences(of: "-", with: "")) { return .binary(4, data) }
        case "$binary":
            if let inner = v.doc, let b = inner["base64"]?.stringValue, let data = Data(base64Encoded: b) {
                let sub = inner["subType"]?.stringValue.flatMap { UInt8($0, radix: 16) } ?? 0
                return .binary(sub, data)
            }
        case "$regularExpression":
            if let inner = v.doc, let p = inner["pattern"]?.stringValue { return .regex(p, inner["options"]?.stringValue ?? "") }
        case "$timestamp":
            if let inner = v.doc, let t = inner["t"]?.number.flatMap({ UInt32(exactly: $0) }), let i = inner["i"]?.number.flatMap({ UInt32(exactly: $0) }) { return .timestamp(t, i) }
        case "$minKey": return .minKey
        case "$maxKey": return .maxKey
        default: break
        }
        return nil
    }
}

enum DateParsing {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let dayOnly: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let noZoneFrac: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"; return f
    }()
    private static let noZone: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }()

    static func parse(_ s: String) -> Date? {
        if let d = isoFrac.date(from: s) ?? iso.date(from: s) { return d }
        if let d = dayOnly.date(from: s) { return d }
        let trimmed = s.replacingOccurrences(of: "Z", with: "")
        if trimmed.count > 20, let d = noZoneFrac.date(from: String(trimmed.prefix(23))) { return d }
        if let d = noZone.date(from: String(trimmed.prefix(19))) { return d }
        return nil
    }

    static func format(_ d: Date) -> String { isoFrac.string(from: d) }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
