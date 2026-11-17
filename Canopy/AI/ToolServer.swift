import Foundation
import Network

/// A tiny MCP server (streamable HTTP, JSON responses) on 127.0.0.1 that
/// gives Claude read-only access to the active connection, plus one tool to
/// hand a query back to the UI. Every call is mirrored in the copilot
/// transcript, so nothing the agent does is hidden.
@MainActor
final class ToolServer {
    static let shared = ToolServer()

    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let token = UUID().uuidString
    weak var app: AppState?

    var url: String { "http://127.0.0.1:\(port)/mcp/\(token)" }

    func start() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in Task { @MainActor in self?.accept(c) } }
        l.stateUpdateHandler = { [weak self] s in
            if case .ready = s, let p = l.port?.rawValue { Task { @MainActor in self?.port = p } }
        }
        l.start(queue: .main)
        listener = l
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: .main)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            Task { @MainActor in
                guard let self else { return }
                var buf = buffer
                if let data { buf.append(data) }
                if let req = HTTPRequest.parse(buf) {
                    let resp = await self.handle(req)
                    c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
                } else if done || err != nil {
                    c.cancel()
                } else {
                    self.receive(c, buffer: buf)
                }
            }
        }
    }

    private func handle(_ req: HTTPRequest) async -> Data {
        guard req.path == "/mcp/\(token)" else { return HTTPRequest.response(404, body: Data()) }
        guard req.method == "POST" else { return HTTPRequest.response(405, body: Data()) }
        guard let msg = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return HTTPRequest.response(400, body: Data())
        }
        guard let id = msg["id"] else { return HTTPRequest.response(202, body: Data()) } // notification
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        var result: Any = [String: Any]()
        switch method {
        case "initialize":
            result = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                      "capabilities": ["tools": [String: Any]()],
                      "serverInfo": ["name": "canopy", "version": "0.1.0"]]
        case "tools/list":
            result = ["tools": CanopyTools.definitions]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = await CanopyTools.call(name, args, app: app)
            result = ["content": [["type": "text", "text": text]], "isError": isError]
        case "ping": result = [String: Any]()
        default:
            let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]])
            return HTTPRequest.response(200, body: body, json: true)
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])) ?? Data()
        return HTTPRequest.response(200, body: body, json: true)
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    static func parse(_ d: Data) -> HTTPRequest? {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: d[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let c = l.firstIndex(of: ":") { headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces) }
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let body = d[end.upperBound...]
        guard body.count >= len else { return nil }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(len)))
    }

    static func response(_ status: Int, body: Data, json: Bool = false) -> Data {
        let text = [200: "OK", 202: "Accepted", 400: "Bad Request", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "OK"
        var h = "HTTP/1.1 \(status) \(text)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if json { h += "Content-Type: application/json\r\n" }
        h += "\r\n"
        return Data(h.utf8) + body
    }
}

/// The tools Claude gets. All reads are capped; writes don't exist here.
enum CanopyTools {
    static let maxChars = 24_000

    static var definitions: [[String: Any]] {
        func tool(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
            ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "required": required], "annotations": ["readOnlyHint": name != "propose_query"]]
        }
        let db = ["type": "string", "description": "Database name"]
        let coll = ["type": "string", "description": "Collection name"]
        let json = { (d: String) in ["type": "string", "description": d] }
        return [
            tool("list_databases", "List databases on the connected deployment with their sizes.", [:], []),
            tool("list_collections", "List collections in a database with document counts and sizes.", ["db": db], ["db"]),
            tool("collection_schema", "Infer a collection's schema from a random sample: every field path, its BSON types, how often it is present, and common values or ranges.", ["db": db, "collection": coll, "sample_size": ["type": "integer", "description": "Documents to sample (default 500, max 2000)"]], ["db", "collection"]),
            tool("find", "Run a read-only find. Arguments are mongosh-syntax strings, e.g. filter '{status: \"refunded\", createdAt: {$gte: ISODate(\"2026-01-01\")}}'. Returns at most 50 documents.", ["db": db, "collection": coll, "filter": json("Filter document"), "projection": json("Projection document"), "sort": json("Sort document"), "limit": ["type": "integer", "description": "Max documents (default 10, max 50)"]], ["db", "collection"]),
            tool("aggregate", "Run a read-only aggregation pipeline (mongosh syntax array). $out and $merge are rejected. Returns at most 50 documents.", ["db": db, "collection": coll, "pipeline": json("Pipeline array, e.g. [{$group: {_id: \"$status\", n: {$sum: 1}}}]"), "limit": ["type": "integer", "description": "Max documents (default 20, max 50)"]], ["db", "collection", "pipeline"]),
            tool("count", "Count documents matching a filter.", ["db": db, "collection": coll, "filter": json("Filter document")], ["db", "collection"]),
            tool("list_indexes", "List a collection's indexes with sizes and how often each has been used.", ["db": db, "collection": coll], ["db", "collection"]),
            tool("explain", "Explain a find query (executionStats): the winning plan, index use, docs and keys examined, time.", ["db": db, "collection": coll, "filter": json("Filter document"), "sort": json("Sort document")], ["db", "collection"]),
            tool("propose_query", "Show the user a query they can apply to Canopy's query bar or pipeline editor with one click. Use this when the user asks for a query, or when a query you found would be useful to them. kind is 'find' or 'aggregate'.", ["db": db, "collection": coll, "kind": ["type": "string", "enum": ["find", "aggregate"]], "title": json("Short title, e.g. 'Refunds over $100k this month'"), "filter": json("find: filter"), "sort": json("find: sort"), "projection": json("find: projection"), "pipeline": json("aggregate: pipeline array")], ["db", "collection", "kind", "title"]),
        ]
    }

    @MainActor
    static func call(_ name: String, _ a: [String: Any], app: AppState?) async -> (String, Bool) {
        guard let app, let session = app.session else { return ("Not connected to a deployment.", true) }
        let svc = session.service
        let db = a["db"] as? String ?? ""
        let coll = a["collection"] as? String ?? ""
        func doc(_ key: String) throws -> BDoc { try ShellParser.parseDocument(a[key] as? String ?? "") }
        func out(_ docs: [BDoc]) -> String {
            let text = BFormat.text(.array(docs.map { .document($0) }), style: .shell)
            return text.count > maxChars ? String(text.prefix(maxChars)) + "\n… (truncated)" : text
        }
        func limit(_ def: Int) -> Int { min(max((a["limit"] as? Int) ?? def, 1), 50) }
        do {
            switch name {
            case "list_databases":
                let dbs = try await svc.listDatabases()
                return (dbs.map { "\($0.name)\t\(Fmt.bytes($0.sizeOnDisk))" }.joined(separator: "\n"), false)
            case "list_collections":
                let cs = try await svc.listCollections(db: db)
                var lines: [String] = []
                for c in cs {
                    let s = c.isView ? nil : try? await svc.collectionStats(db: db, collection: c.name)
                    lines.append("\(c.name)\t\(c.type)\t\(s?.count.map { "\($0) docs" } ?? "")\t\(Fmt.bytes(s?.size))")
                }
                return (lines.joined(separator: "\n"), false)
            case "collection_schema":
                let n = min(max((a["sample_size"] as? Int) ?? 500, 10), 2000)
                let docs = try await svc.sample(db: db, collection: coll, size: n)
                return (SchemaAnalyzer.analyze(docs).summary, false)
            case "find":
                var q = FindQuery()
                q.filter = try doc("filter"); q.projection = try doc("projection"); q.sort = try doc("sort"); q.limit = limit(10)
                let r = try await svc.find(db: db, collection: coll, query: q)
                return ("\(r.documents.count) document(s) in \(Fmt.ms(r.elapsed)):\n" + out(r.documents), false)
            case "aggregate":
                let p = try ShellParser.parseArray(a["pipeline"] as? String ?? "[]")
                if p.contains(where: { ["$out", "$merge"].contains($0.doc?.keys.first ?? "") }) { return ("$out and $merge are not allowed.", true) }
                let r = try await svc.aggregate(db: db, collection: coll, pipeline: p, max: limit(20))
                return ("\(r.documents.count) document(s) in \(Fmt.ms(r.elapsed)):\n" + out(r.documents), false)
            case "count":
                let n = try await svc.count(db: db, collection: coll, filter: try doc("filter"), maxTimeMS: 15_000)
                return (n.map { "\($0)" } ?? "Count timed out", false)
            case "list_indexes":
                let ix = try await svc.indexes(db: db, collection: coll)
                return (ix.map { "\($0.name)\t\(BFormat.text(.document($0.keys), pretty: false))\t\($0.unique ? "unique " : "")\(Fmt.bytes($0.size))\tops: \($0.ops.map(String.init) ?? "?")" }.joined(separator: "\n"), false)
            case "explain":
                var q = FindQuery(); q.filter = try doc("filter"); q.sort = try doc("sort"); q.limit = 0
                let raw = try await svc.explainFind(db: db, collection: coll, query: q)
                let s = ExplainModel.summarize(raw)
                func tree(_ st: ExplainStage, _ depth: Int) -> String {
                    String(repeating: "  ", count: depth) + "\(st.stage) \(st.detail) returned=\(st.nReturned ?? 0) docsExamined=\(st.docsExamined.map(String.init) ?? "-") keysExamined=\(st.keysExamined.map(String.init) ?? "-")\n" + st.children.map { tree($0, depth + 1) }.joined()
                }
                return ("time \(s.ms) ms, returned \(s.nReturned), docs examined \(s.docsExamined), keys examined \(s.keysExamined), indexes: \(s.indexes.joined(separator: ", "))\n" + (s.root.map { tree($0, 0) } ?? ""), false)
            case "propose_query":
                let kind = a["kind"] as? String ?? "find"
                // Validate before showing.
                if kind == "aggregate" { _ = try ShellParser.parseArray(a["pipeline"] as? String ?? "[]") }
                else { _ = try doc("filter"); _ = try doc("sort"); _ = try doc("projection") }
                app.copilot.addProposal(Proposal(db: db, collection: coll, kind: kind, title: a["title"] as? String ?? "Query",
                                                 filter: a["filter"] as? String ?? "", sort: a["sort"] as? String ?? "",
                                                 projection: a["projection"] as? String ?? "", pipeline: a["pipeline"] as? String ?? ""))
                return ("Shown to the user with an Apply button.", false)
            default:
                return ("Unknown tool \(name)", true)
            }
        } catch {
            return (error.localizedDescription, true)
        }
    }
}
