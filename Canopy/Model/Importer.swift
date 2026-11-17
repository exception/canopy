import AppKit
import Foundation

/// Reads JSON arrays, NDJSON (Extended JSON or mongosh syntax) and CSV files into documents.
enum Importer {
    static func read(_ url: URL) throws -> [BDoc] {
        let text = try String(contentsOf: url, encoding: .utf8)
        if url.pathExtension.lowercased() == "csv" { return csv(text) }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("[") { return try ShellParser.parseArray(t).compactMap(\.doc) }
        return try t.split(whereSeparator: \.isNewline).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { try ShellParser.parseDocument(String($0)) }
    }

    static func csv(_ text: String) -> [BDoc] {
        var rows: [[String]] = []
        var row: [String] = [], field = "", quoted = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? it.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } } else { quoted = false }
                } else { field.append(c) }
                continue
            }
            switch c {
            case "\"": quoted = true
            case ",": row.append(field); field = ""
            case "\n", "\r\n": row.append(field); field = ""; rows.append(row); row = []
            case "\r": break
            default: field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard let header = rows.first else { return [] }
        return rows.dropFirst().filter { $0.count > 1 || $0.first?.isEmpty == false }.map { r in
            var d = BDoc()
            for (i, k) in header.enumerated() where i < r.count && !k.isEmpty {
                let v = r[i]
                // Nested paths "a.b" become subdocuments.
                let value: BValue = v.isEmpty ? .null : (Int32(v).map { .int32($0) } ?? Int64(v).map { .int64($0) } ?? (Double(v).map { .double($0) })
                    ?? (v == "true" ? .bool(true) : v == "false" ? .bool(false) : DateParsing.parse(v).map { .date($0) } ?? .string(v)))
                set(&d, path: k.split(separator: ".").map(String.init), value)
            }
            return d
        }
    }

    private static func set(_ d: inout BDoc, path: [String], _ v: BValue) {
        guard let first = path.first else { return }
        if path.count == 1 { d[first] = v; return }
        var sub = d[first]?.doc ?? BDoc()
        set(&sub, path: Array(path.dropFirst()), v)
        d[first] = .document(sub)
    }
}

extension DocumentsModel {
    func importFile(_ url: URL, app: AppState) async {
        guard !session.readOnly else { app.flash("This connection is read-only"); return }
        let docs: [BDoc]
        do { docs = try Importer.read(url) } catch { self.error = "Import: \(error.localizedDescription)"; return }
        guard !docs.isEmpty else { app.flash("Nothing to import"); return }
        let a = NSAlert()
        a.messageText = "Import \(Fmt.count(docs.count)) documents into \(db).\(collection)?"
        a.informativeText = "From \(url.lastPathComponent). First document:\n\(String(BFormat.text(docs[0], pretty: false).prefix(300)))"
        a.addButton(withTitle: "Import")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard await session.authorize("import \(Fmt.count(docs.count)) documents into \(db).\(collection)") else { return }
        loading = true
        var n = 0
        do {
            for chunk in stride(from: 0, to: docs.count, by: 1000) {
                n += try await session.service.insert(db: db, collection: collection, docs: Array(docs[chunk..<min(chunk + 1000, docs.count)]))
            }
            app.flash("Imported \(Fmt.count(n)) documents")
        } catch {
            self.error = "Imported \(n), then: \(error.localizedDescription)"
        }
        loading = false
        await run()
        await session.refreshStat(db, collection)
    }
}
