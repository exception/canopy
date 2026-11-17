import Foundation
import MongoKitten

/// Canopy's own BSON value model. Everything the UI renders, edits, parses or
/// sends to Claude goes through this type; it converts to and from the
/// driver's `Primitive` at the edge.
indirect enum BValue: Hashable {
    case double(Double)
    case string(String)
    case document(BDoc)
    case array([BValue])
    case binary(UInt8, Data)
    case objectId(String)
    case bool(Bool)
    case date(Date)
    case null
    case regex(String, String)
    case javascript(String)
    case int32(Int32)
    case timestamp(UInt32, UInt32) // t, i
    case int64(Int64)
    case decimal(String)
    case minKey
    case maxKey
    case undefined

    var typeName: String {
        switch self {
        case .double: return "Double"
        case .string: return "String"
        case .document: return "Object"
        case .array: return "Array"
        case .binary(let s, _): return s == 4 ? "UUID" : "Binary"
        case .objectId: return "ObjectId"
        case .bool: return "Boolean"
        case .date: return "Date"
        case .null: return "Null"
        case .regex: return "RegExp"
        case .javascript: return "Code"
        case .int32: return "Int32"
        case .timestamp: return "Timestamp"
        case .int64: return "Int64"
        case .decimal: return "Decimal128"
        case .minKey: return "MinKey"
        case .maxKey: return "MaxKey"
        case .undefined: return "Undefined"
        }
    }

    var doc: BDoc? { if case .document(let d) = self { return d }; return nil }
    var arrayValue: [BValue]? { if case .array(let a) = self { return a }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    var number: Double? {
        switch self {
        case .double(let d): return d
        case .int32(let i): return Double(i)
        case .int64(let i): return Double(i)
        case .decimal(let s): return Double(s)
        default: return nil
        }
    }

    var isContainer: Bool {
        switch self { case .document, .array: return true; default: return false }
    }

    /// Value for `$match`-style lookups by dotted path.
    func value(at path: [String]) -> BValue? {
        guard let first = path.first else { return self }
        switch self {
        case .document(let d): return d[first]?.value(at: Array(path.dropFirst()))
        case .array(let a):
            if let i = Int(first), a.indices.contains(i) { return a[i].value(at: Array(path.dropFirst())) }
            return nil
        default: return nil
        }
    }
}

struct BField: Hashable {
    var key: String
    var value: BValue
}

/// An ordered document.
struct BDoc: Hashable {
    var fields: [BField] = []

    init(_ fields: [BField] = []) { self.fields = fields }
    init(_ pairs: [(String, BValue)]) { self.fields = pairs.map { BField(key: $0.0, value: $0.1) } }

    var keys: [String] { fields.map(\.key) }
    var isEmpty: Bool { fields.isEmpty }
    var count: Int { fields.count }

    subscript(key: String) -> BValue? {
        get { fields.first(where: { $0.key == key })?.value }
        set {
            if let i = fields.firstIndex(where: { $0.key == key }) {
                if let v = newValue { fields[i].value = v } else { fields.remove(at: i) }
            } else if let v = newValue {
                fields.append(BField(key: key, value: v))
            }
        }
    }

    var id: BValue? { self["_id"] }
}

// MARK: - Driver bridging

enum BSONBridge {
    static func value(_ p: Primitive?) -> BValue {
        guard let p else { return .null }
        switch p {
        case let d as Document:
            if d.isArray { return .array(d.values.map { value($0) }) }
            return .document(doc(d))
        case let v as Double: return .double(v)
        case let v as String: return .string(v)
        case let v as ObjectId: return .objectId(v.hexString)
        case let v as Bool: return .bool(v)
        case let v as Date: return .date(v)
        case is Null: return .null
        case let v as Int32: return .int32(v)
        case let v as Int: return .int64(Int64(v))
        case let v as Int64: return .int64(v)
        case let v as Timestamp: return .timestamp(UInt32(bitPattern: v.timestamp), UInt32(bitPattern: v.increment))
        case let v as RegularExpression: return .regex(v.pattern, v.options)
        case let v as JavaScriptCode: return .javascript(v.code)
        case let v as JavaScriptCodeWithScope: return .javascript(v.code)
        case let v as Binary: return .binary(subtypeByte(v.subType), v.data)
        case let v as Decimal128:
            let (lo, hi) = decimalParts(v)
            return .decimal(Decimal128Codec.string(low: lo, high: hi))
        case is MinKey: return .minKey
        case is MaxKey: return .maxKey
        default: return .string(String(describing: p))
        }
    }

    static func doc(_ d: Document) -> BDoc {
        var out = BDoc()
        out.fields.reserveCapacity(d.count)
        for (k, v) in d { out.fields.append(BField(key: k, value: value(v))) }
        return out
    }

    static func primitive(_ v: BValue) -> Primitive {
        switch v {
        case .double(let d): return d
        case .string(let s): return s
        case .document(let d): return document(d)
        case .array(let a):
            var d = Document(isArray: true)
            for e in a { d.append(primitive(e)) }
            return d
        case .binary(let sub, let data):
            var payload = withUnsafeBytes(of: Int32(data.count).littleEndian, Array.init)
            payload.append(sub)
            payload.append(contentsOf: data)
            return raw(type: 0x05, payload) ?? Null()
        case .objectId(let h): return ObjectId(h) ?? ObjectId()
        case .bool(let b): return b
        case .date(let d): return d
        case .null, .undefined: return Null()
        case .regex(let p, let o): return RegularExpression(pattern: p, options: String(o.sorted()))
        case .javascript(let c): return JavaScriptCode(c)
        case .int32(let i): return i
        case .timestamp(let t, let i): return Timestamp(increment: Int32(bitPattern: i), timestamp: Int32(bitPattern: t))
        case .int64(let i): return Int(i)
        case .decimal(let s):
            guard let (lo, hi) = Decimal128Codec.parts(s) else { return Double(s) ?? 0 }
            var payload = withUnsafeBytes(of: lo.littleEndian, Array.init)
            payload += withUnsafeBytes(of: hi.littleEndian, Array.init)
            return raw(type: 0x13, payload) ?? Null()
        case .minKey: return MinKey()
        case .maxKey: return MaxKey()
        }
    }

    static func document(_ d: BDoc) -> Document {
        var out = Document()
        for f in d.fields { out[f.key] = primitive(f.value) }
        return out
    }

    /// Builds `{v: <raw>}` from bytes and reads it back: the BSON package keeps
    /// some initializers internal, but parsing raw bytes is public.
    private static func raw(type: UInt8, _ payload: [UInt8]) -> Primitive? {
        var body: [UInt8] = [type, 0x76, 0x00] + payload + [0x00]
        let len = Int32(body.count + 4)
        body.insert(contentsOf: withUnsafeBytes(of: len.littleEndian, Array.init), at: 0)
        return Document(bytes: body)["v"]
    }

    private static func decimalParts(_ d: Decimal128) -> (UInt64, UInt64) {
        var lo: UInt64 = 0, hi: UInt64 = 0
        for c in Mirror(reflecting: d).children {
            if c.label == "low", let v = c.value as? UInt64 { lo = v }
            if c.label == "high", let v = c.value as? UInt64 { hi = v }
        }
        // The package reads both halves big-endian; BSON stores them little-endian.
        return (lo.byteSwapped, hi.byteSwapped)
    }

    private static func subtypeByte(_ s: Binary.SubType) -> UInt8 {
        switch s {
        case .generic: return 0
        case .function: return 1
        case .uuid: return 4
        case .md5: return 5
        case .userDefined(let b): return b
        @unknown default: return 0
        }
    }
}

// MARK: - Decimal128 (IEEE 754-2008 BID) <-> string

enum Decimal128Codec {
    static func string(low: UInt64, high: UInt64) -> String {
        let negative = high >> 63 == 1
        let comb = (high >> 58) & 0x1f
        if comb == 0x1f { return "NaN" }
        if comb == 0x1e { return negative ? "-Infinity" : "Infinity" }
        let exponent: Int
        var coeff: UInt128
        if (high >> 61) & 3 == 3 {
            exponent = Int((high >> 47) & 0x3fff) - 6176
            coeff = 0 // non-canonical: always > max significand, treated as zero
        } else {
            exponent = Int((high >> 49) & 0x3fff) - 6176
            coeff = (UInt128(high & 0x1_ffff_ffff_ffff) << 64) | UInt128(low)
        }
        if coeff > UInt128("9999999999999999999999999999999999")! { coeff = 0 }
        let digits = String(coeff)
        let sign = negative ? "-" : ""
        let adjusted = exponent + digits.count - 1
        if exponent <= 0 && adjusted >= -6 {
            if exponent == 0 { return sign + digits }
            let pointPos = digits.count + exponent
            if pointPos > 0 {
                let i = digits.index(digits.startIndex, offsetBy: pointPos)
                return sign + digits[..<i] + "." + digits[i...]
            }
            return sign + "0." + String(repeating: "0", count: -pointPos) + digits
        }
        var s = String(digits.first!)
        if digits.count > 1 { s += "." + digits.dropFirst() }
        return sign + s + "E" + (adjusted >= 0 ? "+" : "") + String(adjusted)
    }

    static func parts(_ input: String) -> (UInt64, UInt64)? {
        var s = input.trimmingCharacters(in: .whitespaces)
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        let lower = s.lowercased()
        let signBit: UInt64 = negative ? 1 << 63 : 0
        if lower == "nan" { return (0, 0x7c00_0000_0000_0000) }
        if lower == "inf" || lower == "infinity" { return (0, signBit | 0x7800_0000_0000_0000) }
        var exp = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let v = Int(s[s.index(after: e)...]) else { return nil }
            exp = v
            s = String(s[..<e])
        }
        var digits = ""
        if let dot = s.firstIndex(of: ".") {
            let frac = s[s.index(after: dot)...]
            exp -= frac.count
            digits = String(s[..<dot]) + frac
        } else { digits = s }
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        while digits.count > 1 && digits.hasPrefix("0") { digits.removeFirst() }
        while digits.count > 34 && digits.hasSuffix("0") { digits.removeLast(); exp += 1 }
        guard digits.count <= 34, let coeff = UInt128(digits) else { return nil }
        let biased = exp + 6176
        guard biased >= 0 && biased <= 0x2fff else { return nil }
        let high = signBit | (UInt64(biased) << 49) | UInt64(coeff >> 64)
        let low = UInt64(truncatingIfNeeded: coeff)
        return (low, high)
    }
}
