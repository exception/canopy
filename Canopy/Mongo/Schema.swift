import Foundation

/// Field-by-field shape of a collection, inferred from a sample.
struct SchemaField: Identifiable {
    var path: String
    var name: String
    var depth: Int
    var presence: Int = 0           // docs (or array elements) that have the field
    var types: [String: Int] = [:]
    var topValues: [(String, Int)] = []
    var distinct: Int = 0
    var numbers: [Double] = []
    var dates: [Date] = []
    var lengths: [Int] = []         // array lengths
    var sampleValues: [BValue] = []
    var id: String { path }

    var total: Int { types.values.reduce(0, +) }
    var dominantType: String { types.max { $0.value < $1.value }?.key ?? "—" }
    var isMixed: Bool { types.filter { $0.key != "Null" }.count > 1 }
}

struct SchemaReport {
    var sampled: Int
    var fields: [SchemaField]
    var elapsed: TimeInterval

    func presence(_ f: SchemaField) -> Double { sampled == 0 ? 0 : Double(f.presence) / Double(sampled) }

    /// Compact text for Claude: path, types, presence, examples.
    var summary: String {
        var lines = ["Sampled \(sampled) documents."]
        for f in fields.prefix(150) {
            let types = f.types.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            var line = "\(f.path): \(types); present in \(Int((presence(f) * 100).rounded()))%"
            if !f.topValues.isEmpty && f.distinct <= 30 {
                line += "; values: " + f.topValues.prefix(8).map { "\($0.0)×\($0.1)" }.joined(separator: ", ")
            } else if let ex = f.sampleValues.first {
                line += "; e.g. " + String(BFormat.text(ex, pretty: false).prefix(80))
            }
            if let mn = f.numbers.min(), let mx = f.numbers.max() { line += "; range \(BFormat.number(mn))…\(BFormat.number(mx))" }
            if let mn = f.dates.min(), let mx = f.dates.max() { line += "; from \(DateParsing.format(mn)) to \(DateParsing.format(mx))" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

enum SchemaAnalyzer {
    static func analyze(_ docs: [BDoc], elapsed: TimeInterval = 0) -> SchemaReport {
        var map: [String: SchemaField] = [:]
        var order: [String] = []
        var valueCounts: [String: [String: Int]] = [:]

        var seen = Set<String>() // paths already counted for the current document

        func visit(_ d: BDoc, prefix: String, depth: Int) {
            for f in d.fields {
                let path = prefix.isEmpty ? f.key : prefix + "." + f.key
                if map[path] == nil {
                    map[path] = SchemaField(path: path, name: f.key, depth: depth)
                    order.append(path)
                }
                if seen.insert(path).inserted { map[path]!.presence += 1 }
                record(f.value, path: path, depth: depth)
            }
        }

        func record(_ v: BValue, path: String, depth: Int) {
            map[path]!.types[v.typeName, default: 0] += 1
            if map[path]!.sampleValues.count < 5, !v.isContainer { map[path]!.sampleValues.append(v) }
            switch v {
            case .document(let sub): visit(sub, prefix: path, depth: depth + 1)
            case .array(let items):
                map[path]!.lengths.append(items.count)
                // Array elements are described under "path[]"? Keep it simple:
                // documents inside arrays merge into the same dotted paths, which
                // is also how queries address them.
                for item in items {
                    if case .document(let sub) = item { visit(sub, prefix: path, depth: depth + 1) }
                    else { scalar(item, path: path) }
                }
            default: scalar(v, path: path)
            }
        }

        func scalar(_ v: BValue, path: String) {
            if let n = v.number { map[path]!.numbers.append(n) }
            if case .date(let d) = v { map[path]!.dates.append(d) }
            switch v {
            case .string(let s) where s.count <= 80: valueCounts[path, default: [:]][s, default: 0] += 1
            case .bool(let b): valueCounts[path, default: [:]][b ? "true" : "false", default: 0] += 1
            case .int32, .int64: valueCounts[path, default: [:]][BFormat.preview(v), default: 0] += 1
            case .null: valueCounts[path, default: [:]]["null", default: 0] += 1
            default: break
            }
        }

        for d in docs { seen.removeAll(keepingCapacity: true); visit(d, prefix: "", depth: 0) }

        var fields = order.compactMap { map[$0] }
        for i in fields.indices {
            if let counts = valueCounts[fields[i].path] {
                fields[i].distinct = counts.count
                fields[i].topValues = counts.sorted { $0.value > $1.value }.prefix(12).map { ($0.key, $0.value) }
            }
        }
        // _id first, then document order with children right after parents.
        fields.sort { a, b in
            if a.path == "_id" { return true }
            if b.path == "_id" { return false }
            return order.firstIndex(of: a.path)! < order.firstIndex(of: b.path)!
        }
        fields = treeOrder(fields)
        return SchemaReport(sampled: docs.count, fields: fields, elapsed: elapsed)
    }

    private static func treeOrder(_ fields: [SchemaField]) -> [SchemaField] {
        var out: [SchemaField] = []
        func children(of prefix: String, depth: Int) {
            for f in fields where f.depth == depth && (depth == 0 || f.path.hasPrefix(prefix + ".")) {
                if depth > 0 && f.path.dropFirst(prefix.count + 1).contains(".") { continue }
                out.append(f)
                children(of: f.path, depth: depth + 1)
            }
        }
        children(of: "", depth: 0)
        return out
    }
}
