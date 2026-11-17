import Foundation
import Observation

struct Proposal: Identifiable, Hashable {
    var id = UUID()
    var db: String
    var collection: String
    var kind: String
    var title: String
    var filter: String
    var sort: String
    var projection: String
    var pipeline: String
    var applied = false
}

struct ToolCall: Identifiable, Hashable {
    var id: String
    var name: String
    var input: String
    var result: String?
    var isError = false
    var started = Date()
    var finished: Date?
    var expanded = false

    var label: String {
        let n = name.replacingOccurrences(of: "mcp__canopy__", with: "")
        return n.replacingOccurrences(of: "_", with: " ")
    }
}

enum CopilotPart: Identifiable, Hashable {
    case text(id: UUID, String)
    case tool(ToolCall)
    case proposal(Proposal)

    var id: String {
        switch self {
        case .text(let id, _): return id.uuidString
        case .tool(let t): return t.id
        case .proposal(let p): return p.id.uuidString
        }
    }
}

struct CopilotMessage: Identifiable, Hashable {
    var id = UUID()
    var role: String // user | assistant
    var parts: [CopilotPart]
    var error: String?
    var cost: Double?
}

@MainActor @Observable
final class CopilotModel {
    weak var app: AppState?
    var messages: [CopilotMessage] = []
    var input = ""
    var busy = false
    var sessionID: String?
    private var handle: ClaudeCLI.Handle?
    private var streamingText = ""

    var suggestions: [String] {
        guard let tab = app?.currentTab, tab.kind != .server else {
            return ["Which collections are the largest, and what's in them?", "Are there collections without useful indexes?"]
        }
        return ["Summarize what's in \(tab.collection)", "Find anything unusual in \(tab.collection)'s data",
                "Which queries on \(tab.collection) would need an index?", "Write a pipeline: top 10 by count of the most interesting field"]
    }

    func send(_ text: String? = nil) {
        let prompt = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !busy, let app else { return }
        input = ""
        messages.append(CopilotMessage(role: "user", parts: [.text(id: UUID(), prompt)]))
        messages.append(CopilotMessage(role: "assistant", parts: []))
        busy = true
        streamingText = ""
        let h = ClaudeCLI.Handle()
        handle = h
        ToolServer.shared.start()
        let system = systemPrompt(app)
        let full = contextLine(app) + "\n\n" + prompt
        let stream = ClaudeCLI.stream(prompt: full, system: system, resume: sessionID, mcpURL: ToolServer.shared.url, handle: h)
        Task {
            for await ev in stream { self.process(ev) }
            busy = false
        }
    }

    func stop() { handle?.cancel(); busy = false }

    func reset() {
        stop()
        messages = []
        sessionID = nil
    }

    private func process(_ ev: ClaudeCLI.Event) {
        guard !messages.isEmpty else { return }
        let i = messages.count - 1
        switch ev {
        case .session(let s): sessionID = s
        case .textDelta(let t):
            streamingText += t
            if case .text(let id, _)? = messages[i].parts.last {
                messages[i].parts[messages[i].parts.count - 1] = .text(id: id, streamingText)
            } else {
                messages[i].parts.append(.text(id: UUID(), streamingText))
            }
        case .text(let t):
            // Full block arrives after its deltas; make sure the final text wins.
            if case .text(let id, _)? = messages[i].parts.last { messages[i].parts[messages[i].parts.count - 1] = .text(id: id, t) }
            else { messages[i].parts.append(.text(id: UUID(), t)) }
            streamingText = ""
        case .toolUse(let id, let name, let input):
            streamingText = ""
            let pretty = input.map { k, v in "\(k): \(v)" }.sorted().joined(separator: "\n")
            if name.hasSuffix("propose_query") { return } // shown as a proposal card instead
            messages[i].parts.append(.tool(ToolCall(id: id, name: name, input: pretty)))
        case .toolResult(let id, let text, let isError):
            for (pi, p) in messages[i].parts.enumerated() {
                if case .tool(var t) = p, t.id == id {
                    t.result = text; t.isError = isError; t.finished = Date()
                    messages[i].parts[pi] = .tool(t)
                }
            }
        case .done(let cost, let error):
            messages[i].cost = cost
            messages[i].error = error
        }
    }

    func addProposal(_ p: Proposal) {
        guard !messages.isEmpty else { return }
        streamingText = ""
        messages[messages.count - 1].parts.append(.proposal(p))
    }

    func toggle(tool id: String) {
        for (mi, m) in messages.enumerated() {
            for (pi, p) in m.parts.enumerated() {
                if case .tool(var t) = p, t.id == id { t.expanded.toggle(); messages[mi].parts[pi] = .tool(t) }
            }
        }
    }

    func apply(_ p: Proposal) {
        guard let app else { return }
        let tab = app.open(db: p.db, collection: p.collection)
        if p.kind == "aggregate" {
            tab.mode = .aggregations
            if let pipe = try? ShellParser.parseArray(p.pipeline) { tab.agg.load(pipeline: pipe) }
            Task { await tab.agg.refreshPreviews(); await tab.agg.run() }
        } else {
            tab.mode = .documents
            tab.docs.apply(filter: p.filter, sort: p.sort, project: p.projection)
            Task { await tab.docs.run() }
        }
        for (mi, m) in messages.enumerated() {
            for (pi, part) in m.parts.enumerated() {
                if case .proposal(var q) = part, q.id == p.id { q.applied = true; messages[mi].parts[pi] = .proposal(q) }
            }
        }
    }

    private func contextLine(_ app: AppState) -> String {
        var s = "[Canopy context: connected to \(app.session?.saved.name ?? "nothing") (\(app.session?.saved.host ?? "")), MongoDB \(app.session?.service.serverVersion ?? "?")"
        if let t = app.currentTab, t.kind != .server {
            s += "; the user is looking at \(t.namespace) (\(t.mode.rawValue) tab)"
            if !t.docs.filterText.isEmpty { s += " with filter \(t.docs.filterText)" }
            if let sel = t.docs.selected, t.docs.docs.indices.contains(sel) {
                s += "; selected document: " + String(BFormat.text(t.docs.docs[sel], pretty: false).prefix(1500))
            }
        }
        return s + "]"
    }

    private func systemPrompt(_ app: AppState) -> String {
        """
        You are the assistant inside Canopy, a native macOS MongoDB client. You help the user understand and query their data.
        You have read-only tools for the connected deployment (prefixed canopy). Use them to look at real data before answering; never guess field names: \
        check collection_schema first when you don't know a collection's shape. Keep tool results small (use projections and limits).
        When the user wants a query or pipeline, or one you used would be useful to keep, call propose_query so they get an Apply button; \
        don't only paste it in text. Queries use mongosh syntax.
        Answer concisely in Markdown. Lead with the answer. Use short tables for numbers. Current time: \(AIPrompts.today()).
        """
    }
}

/// One-shot AI features (query bar, pipeline, schema, explain, indexes).
@MainActor
enum AIActions {
    private static func schemaText(_ session: Session, _ db: String, _ coll: String, sample: Int = 300) async -> String {
        guard let docs = try? await session.service.sample(db: db, collection: coll, size: sample) else { return "(unavailable)" }
        return SchemaAnalyzer.analyze(docs).summary
    }

    static func ask(_ m: DocumentsModel) async {
        let request = m.askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        m.askBusy = true
        m.askError = nil
        defer { m.askBusy = false }
        let schema = await schemaText(m.session, m.db, m.collection)
        let current = "filter \(m.filterText.isEmpty ? "{}" : m.filterText), sort \(m.sortText.isEmpty ? "{}" : m.sortText), projection \(m.projectText.isEmpty ? "{}" : m.projectText)"
        let system = """
        You turn plain-language requests into a MongoDB find query for Canopy's query bar. \(AIPrompts.syntax)
        If the request refines the current query, build on it. Leave sort and projection empty unless asked or clearly implied \
        ("latest" implies a sort). If the request needs grouping or joins, still give the best find query and say so in the note.
        note: one short sentence describing what the query does, in plain words.
        """
        let schemaDef: [String: Any] = ["type": "object", "properties": [
            "filter": ["type": "string"], "sort": ["type": "string"], "projection": ["type": "string"], "note": ["type": "string"],
        ], "required": ["filter", "sort", "projection", "note"], "additionalProperties": false]
        do {
            let r = try await ClaudeCLI.structured(prompt: AIPrompts.queryRequest(ns: "\(m.db).\(m.collection)", schema: schema, current: current, request: request), system: system, schema: schemaDef)
            let f = clean(r["filter"] as? String), s = clean(r["sort"] as? String), p = clean(r["projection"] as? String)
            _ = try ShellParser.parseDocument(f); _ = try ShellParser.parseDocument(s); _ = try ShellParser.parseDocument(p)
            m.apply(filter: f, sort: s, project: p)
            m.askNote = r["note"] as? String
            await m.run()
        } catch {
            m.askError = error.localizedDescription
        }
    }

    static func pipeline(_ m: AggregationModel) async {
        let request = m.askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        m.askBusy = true
        m.askError = nil
        defer { m.askBusy = false }
        let schema = await schemaText(m.session, m.db, m.collection)
        let current = m.stages.isEmpty ? "(empty)" : m.pipelineShell
        let system = """
        You write MongoDB aggregation pipelines for Canopy's pipeline builder. \(AIPrompts.syntax)
        Return each stage as {op, body}: op is the stage operator like "$group", body is that operator's argument in mongosh syntax. \
        If the request refines the current pipeline, return the whole updated pipeline. Never use $out or $merge unless asked.
        note: one short sentence describing what the pipeline does.
        """
        let schemaDef: [String: Any] = ["type": "object", "properties": [
            "stages": ["type": "array", "items": ["type": "object", "properties": ["op": ["type": "string"], "body": ["type": "string"]], "required": ["op", "body"], "additionalProperties": false]],
            "note": ["type": "string"],
        ], "required": ["stages", "note"], "additionalProperties": false]
        do {
            let r = try await ClaudeCLI.structured(prompt: AIPrompts.queryRequest(ns: "\(m.db).\(m.collection)", schema: schema, current: current, request: request), system: system, schema: schemaDef)
            let stages = (r["stages"] as? [[String: Any]] ?? []).map { PipelineStage(op: $0["op"] as? String ?? "$match", body: clean($0["body"] as? String)) }
            for s in stages {
                if let v = try? ShellParser.parse(s.body) { s.body = BFormat.text(v) } // normalize formatting
                _ = try s.value()
            }
            m.stages = stages
            m.askNote = r["note"] as? String
            await m.refreshPreviews()
            await m.run()
        } catch {
            m.askError = error.localizedDescription
        }
    }

    static func schemaInsight(_ m: SchemaModel) async {
        guard let report = m.report else { return }
        m.insightBusy = true
        defer { m.insightBusy = false }
        let system = """
        You review MongoDB collection schemas inferred from a sample. Write 3 to 6 short Markdown bullets: what the collection holds, \
        then concrete data-quality issues worth fixing (mixed types, optional fields that look required, suspicious values, unbounded arrays), \
        each naming the field. No preamble, no headings.
        """
        do {
            let r = try await ClaudeCLI.structured(prompt: "Collection \(m.db).\(m.collection)\n\n\(report.summary)", system: system,
                                                   schema: ["type": "object", "properties": ["markdown": ["type": "string"]], "required": ["markdown"]])
            m.insight = r["markdown"] as? String
        } catch { m.insight = "⚠️ " + error.localizedDescription }
    }

    static func explain(_ m: ExplainModel) async {
        guard let s = m.summary else { return }
        m.analysisBusy = true
        defer { m.analysisBusy = false }
        let indexes = (try? await m.session.service.indexes(db: m.db, collection: m.collection)) ?? []
        let ixText = indexes.map { "\($0.name) \(BFormat.text(.document($0.keys), pretty: false))" }.joined(separator: "\n")
        let system = """
        You are a MongoDB performance expert. Given a query's explain output and the collection's indexes, say in Markdown: \
        whether it is efficient (one line verdict first, bold), why (docs/keys examined vs returned, COLLSCAN, in-memory SORT), \
        and the single best fix, with the exact createIndex keys following the ESR rule (equality, sort, range) when an index would help. Max 120 words.
        """
        let prompt = "Query on \(m.db).\(m.collection): \(m.queryLabel)\n\nIndexes:\n\(ixText)\n\nExplain (executionStats):\n\(String(BFormat.text(.document(s.raw), pretty: false).prefix(12000)))"
        do {
            let r = try await ClaudeCLI.structured(prompt: prompt, system: system, schema: ["type": "object", "properties": ["markdown": ["type": "string"]], "required": ["markdown"]])
            m.analysis = r["markdown"] as? String
        } catch { m.analysis = "⚠️ " + error.localizedDescription }
    }

    static func suggestIndexes(_ m: IndexesModel) async {
        m.suggestBusy = true
        defer { m.suggestBusy = false }
        let schema = await schemaText(m.session, m.db, m.collection)
        let ns = "\(m.db).\(m.collection)"
        let recent = History.shared.entries(for: ns).prefix(25).map { $0.kind == "find" ? "find filter=\($0.filter) sort=\($0.sort)" : "aggregate \($0.pipeline)" }.joined(separator: "\n")
        let existing = m.indexes.map { "\($0.name) \(BFormat.text(.document($0.keys), pretty: false)) ops=\($0.ops.map(String.init) ?? "?")" }.joined(separator: "\n")
        let system = """
        You recommend MongoDB indexes. Use the recent queries run against the collection (most important), the schema, and existing indexes. \
        Follow the ESR rule. Don't suggest an index an existing one already covers as a prefix. Suggest at most 3, fewer is fine. \
        Also flag existing indexes that are unused (ops=0) and redundant in the note. keys and options are mongosh-syntax documents.
        """
        let schemaDef: [String: Any] = ["type": "object", "properties": [
            "suggestions": ["type": "array", "items": ["type": "object", "properties": ["keys": ["type": "string"], "options": ["type": "string"], "reason": ["type": "string"]], "required": ["keys", "options", "reason"], "additionalProperties": false]],
            "note": ["type": "string"],
        ], "required": ["suggestions", "note"], "additionalProperties": false]
        do {
            let r = try await ClaudeCLI.structured(prompt: "Collection \(ns)\n\nRecent queries:\n\(recent.isEmpty ? "(none recorded)" : recent)\n\nExisting indexes:\n\(existing)\n\nSchema:\n\(schema)", system: system, schema: schemaDef)
            m.suggestions = (r["suggestions"] as? [[String: Any]] ?? []).map {
                AISuggestion(keys: clean($0["keys"] as? String), options: clean($0["options"] as? String), reason: $0["reason"] as? String ?? "")
            }
            m.suggestNote = r["note"] as? String
        } catch { m.suggestNote = "⚠️ " + error.localizedDescription }
    }

    static func update(_ m: BulkModel) async {
        let request = m.askText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        m.askBusy = true
        m.askError = nil
        defer { m.askBusy = false }
        let schema = await schemaText(m.session, m.db, m.collection)
        let system = """
        You write MongoDB updateMany arguments for Canopy's bulk update. \(AIPrompts.syntax)
        Return the filter (which documents) and the update: either an update operator document like { $set: { … } } \
        or an aggregation pipeline array when the new value depends on other fields. Prefer the narrowest correct filter. \
        If the request only describes the change, keep the current filter.
        note: one short sentence saying what will change.
        """
        let schemaDef: [String: Any] = ["type": "object", "properties": [
            "filter": ["type": "string"], "update": ["type": "string"], "note": ["type": "string"],
        ], "required": ["filter", "update", "note"], "additionalProperties": false]
        do {
            let r = try await ClaudeCLI.structured(prompt: AIPrompts.queryRequest(ns: "\(m.db).\(m.collection)", schema: schema, current: "filter \(m.filterText.isEmpty ? "{}" : m.filterText)", request: request), system: system, schema: schemaDef)
            let f = clean(r["filter"] as? String), u = (r["update"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try ShellParser.parseDocument(f); _ = try ShellParser.parse(u)
            m.filterText = f
            if let v = try? ShellParser.parse(u) { m.updateText = BFormat.text(v) } else { m.updateText = u }
            m.askNote = r["note"] as? String
            await m.preview()
        } catch {
            m.askError = error.localizedDescription
        }
    }

    private static func clean(_ s: String?) -> String {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t == "{}" ? "" : t
    }
}
