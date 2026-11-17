import Foundation
import Observation

enum WorkspaceMode: String, CaseIterable, Identifiable {
    case documents = "Documents", aggregations = "Aggregations", schema = "Schema", indexes = "Indexes", explain = "Explain"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .documents: return "doc.text"
        case .aggregations: return "line.3.horizontal.decrease"
        case .schema: return "chart.bar.xaxis"
        case .indexes: return "bolt.horizontal"
        case .explain: return "gauge.with.dots.needle.33percent"
        }
    }
}

enum DocViewMode: String, CaseIterable, Identifiable {
    case list = "List", table = "Table", json = "JSON"
    var id: String { rawValue }
    var icon: String {
        switch self { case .list: return "list.bullet.indent"; case .table: return "tablecells"; case .json: return "curlybraces" }
    }
}

/// One open tab: a collection workspace, or the server overview.
@MainActor @Observable
final class WorkspaceTab: Identifiable {
    enum Kind: Equatable { case collection(db: String, name: String), server }
    let id = UUID()
    let kind: Kind
    var mode: WorkspaceMode = .documents
    let docs: DocumentsModel
    let agg: AggregationModel
    let schema: SchemaModel
    let indexes: IndexesModel
    let explain: ExplainModel

    init(kind: Kind, session: Session) {
        self.kind = kind
        let (db, coll): (String, String) = { if case .collection(let d, let c) = kind { return (d, c) }; return ("", "") }()
        docs = DocumentsModel(session: session, db: db, collection: coll)
        agg = AggregationModel(session: session, db: db, collection: coll)
        schema = SchemaModel(session: session, db: db, collection: coll)
        indexes = IndexesModel(session: session, db: db, collection: coll)
        explain = ExplainModel(session: session, db: db, collection: coll)
    }

    var db: String { if case .collection(let d, _) = kind { return d }; return "" }
    var collection: String { if case .collection(_, let c) = kind { return c }; return "" }
    var title: String { kind == .server ? "Server" : collection }
    var namespace: String { "\(db).\(collection)" }
}

// MARK: - Documents

@MainActor @Observable
final class DocumentsModel {
    let session: Session
    let db: String
    let collection: String

    var filterText = ""
    var projectText = ""
    var sortText = ""
    var limit = 50
    var page = 0
    var showOptions = false

    var docs: [BDoc] = []
    var total: Int?
    var countTimedOut = false
    var elapsed: TimeInterval = 0
    var loading = false
    var error: String?
    var view: DocViewMode = .list
    var selected: Int?
    var hasRun = false
    var lastQuery = FindQuery()

    // Inline editing
    var editing: Int?          // index in docs, or -1 for a new document
    var editText = ""
    var editError: String?

    // Live change stream
    var live = false
    var events: [ChangeEvent] = []
    var liveError: String?
    var newSinceRun = 0
    private var liveTask: Task<Void, Never>?

    // AI
    var askText = ""
    var askBusy = false
    var askNote: String?
    var askError: String?

    var columns: [String] {
        var seen = Set<String>(), out: [String] = []
        if docs.contains(where: { $0["_id"] != nil }) { out.append("_id"); seen.insert("_id") }
        for d in docs { for k in d.keys where !seen.contains(k) { seen.insert(k); out.append(k) } }
        return out
    }

    init(session: Session, db: String, collection: String) {
        self.session = session
        self.db = db
        self.collection = collection
    }

    func buildQuery() throws -> FindQuery {
        var q = FindQuery()
        do { q.filter = try ShellParser.parseDocument(filterText) } catch { throw ParseError(message: "Filter: \(error.localizedDescription)", offset: 0) }
        do { q.projection = try ShellParser.parseDocument(projectText) } catch { throw ParseError(message: "Project: \(error.localizedDescription)", offset: 0) }
        do { q.sort = try ShellParser.parseDocument(sortText) } catch { throw ParseError(message: "Sort: \(error.localizedDescription)", offset: 0) }
        q.limit = limit
        q.skip = page * limit
        return q
    }

    /// Live validation for the query bar.
    var filterError: String? {
        guard !filterText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do { _ = try ShellParser.parseDocument(filterText); return nil } catch { return error.localizedDescription }
    }

    func run(resetPage: Bool = true, record: Bool = true) async {
        if resetPage { page = 0 }
        let q: FindQuery
        do { q = try buildQuery() } catch { self.error = error.localizedDescription; return }
        loading = true
        error = nil
        newSinceRun = 0
        defer { loading = false; hasRun = true }
        do {
            let r = try await session.service.find(db: db, collection: collection, query: q)
            docs = r.documents
            elapsed = r.elapsed
            lastQuery = q
            if selected.map({ $0 >= docs.count }) ?? false { selected = nil }
            if resetPage {
                total = nil
                countTimedOut = false
                let n = try? await session.service.count(db: db, collection: collection, filter: q.filter)
                total = n
                countTimedOut = n == nil
            }
            if record && resetPage { History.shared.record(namespace: "\(db).\(collection)", kind: "find", filter: filterText, sort: sortText, project: projectText, pipeline: "") }
        } catch {
            self.error = error.localizedDescription
            docs = []
        }
    }

    func next() async { page += 1; await run(resetPage: false) }
    func prev() async { page = max(0, page - 1); await run(resetPage: false) }

    func reset() async {
        filterText = ""; projectText = ""; sortText = ""; askNote = nil
        await run()
    }

    var rangeLabel: String {
        guard !docs.isEmpty else { return total == 0 ? "No documents" : "—" }
        let a = page * limit + 1, b = page * limit + docs.count
        let t = total.map { Fmt.count($0) } ?? (countTimedOut ? "many" : "…")
        return "\(Fmt.count(a))–\(Fmt.count(b)) of \(t)"
    }

    var canNext: Bool { docs.count == limit && (total.map { (page + 1) * limit < $0 } ?? true) }

    // MARK: Editing

    func beginEdit(_ i: Int) {
        editing = i
        editText = BFormat.text(docs[i])
        editError = nil
        selected = i
    }

    func beginInsert(template: BDoc? = nil) {
        editing = -1
        var t = template ?? BDoc()
        t["_id"] = nil
        editText = t.isEmpty ? "{\n  \n}" : BFormat.text(t)
        editError = nil
    }

    func saveEdit() async -> Bool {
        guard let i = editing else { return false }
        guard !session.readOnly else { editError = "This connection is read-only."; return false }
        do {
            let d = try ShellParser.parseDocument(editText)
            if i == -1 {
                _ = try await session.service.insert(db: db, collection: collection, docs: [d])
            } else {
                guard let id = docs[i]["_id"] else { editError = "Document has no _id"; return false }
                try await session.service.replace(db: db, collection: collection, id: id, with: d)
                docs[i] = d.id == nil ? BDoc([("_id", id)] + d.fields.map { ($0.key, $0.value) }) : d
            }
            editing = nil
            if i == -1 { await run(resetPage: false) }
            Task { await session.refreshStat(db, collection) }
            return true
        } catch {
            editError = error.localizedDescription
            return false
        }
    }

    func delete(_ i: Int) async {
        guard !session.readOnly, docs.indices.contains(i), let id = docs[i]["_id"] else { return }
        do {
            try await session.service.delete(db: db, collection: collection, id: id)
            docs.remove(at: i)
            total = total.map { $0 - 1 }
            selected = nil
            Task { await session.refreshStat(db, collection) }
        } catch { self.error = error.localizedDescription }
    }

    func toggleLive() {
        if live { stopLive(); return }
        live = true
        liveError = nil
        let stream = session.service.watch(db: db, collection: collection)
        liveTask = Task {
            do {
                for try await e in stream {
                    events.insert(ChangeEvent(e), at: 0)
                    newSinceRun += 1
                    if events.count > 300 { events.removeLast() }
                    if total != nil, e["operationType"] == .string("insert") { total! += 1 }
                    if e["operationType"] == .string("delete") { total = total.map { $0 - 1 } }
                }
            } catch {
                liveError = error.localizedDescription
            }
            live = false
        }
    }

    func stopLive() {
        liveTask?.cancel()
        liveTask = nil
        live = false
    }

    /// Adds `path: value` to the current filter and runs it.
    func addFilter(path: String, value: BValue) async {
        var f = (try? ShellParser.parseDocument(filterText)) ?? BDoc()
        f[path] = value
        filterText = BFormat.text(f, pretty: false)
        await run()
    }

    func apply(filter: String?, sort: String?, project: String?) {
        filterText = filter ?? ""
        sortText = sort ?? ""
        projectText = project ?? ""
        if !(sortText.isEmpty && projectText.isEmpty) { showOptions = true }
    }
}

// MARK: - Aggregations

@MainActor @Observable
final class PipelineStage: Identifiable {
    let id = UUID()
    var op: String
    var body: String
    var enabled = true
    var collapsed = false
    var preview: [BDoc] = []
    var previewError: String?
    var previewLoading = false
    var previewElapsed: TimeInterval = 0

    init(op: String, body: String) { self.op = op; self.body = body }

    func value() throws -> BValue {
        let v = try ShellParser.parse(body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : body)
        return .document(BDoc([(op, v)]))
    }

    static let operators = ["$match", "$project", "$group", "$sort", "$limit", "$skip", "$unwind", "$lookup", "$addFields", "$set", "$unset",
                            "$count", "$facet", "$bucket", "$bucketAuto", "$sortByCount", "$replaceRoot", "$sample", "$geoNear", "$densify", "$fill",
                            "$setWindowFields", "$unionWith", "$graphLookup", "$redact", "$out", "$merge"]

    static func template(_ op: String) -> String {
        switch op {
        case "$match": return "{\n  \n}"
        case "$group": return "{\n  _id: \"$field\",\n  count: { $sum: 1 }\n}"
        case "$sort": return "{ field: -1 }"
        case "$limit": return "10"
        case "$skip": return "0"
        case "$unwind": return "\"$field\""
        case "$lookup": return "{\n  from: \"collection\",\n  localField: \"field\",\n  foreignField: \"_id\",\n  as: \"joined\"\n}"
        case "$count": return "\"count\""
        case "$sortByCount": return "\"$field\""
        case "$sample": return "{ size: 10 }"
        case "$replaceRoot": return "{ newRoot: \"$field\" }"
        case "$facet": return "{\n  byX: [{ $sortByCount: \"$x\" }]\n}"
        case "$bucket": return "{\n  groupBy: \"$field\",\n  boundaries: [0, 100, 1000],\n  default: \"other\"\n}"
        case "$unset": return "\"field\""
        default: return "{\n  \n}"
        }
    }
}

@MainActor @Observable
final class AggregationModel {
    let session: Session
    let db: String
    let collection: String
    var stages: [PipelineStage] = []
    var results: [BDoc] = []
    var resultsElapsed: TimeInterval = 0
    var running = false
    var error: String?
    var textMode = false
    var pipelineText = ""
    var askText = ""
    var askBusy = false
    var askNote: String?
    var askError: String?
    var selectedResult: Int?

    init(session: Session, db: String, collection: String) {
        self.session = session
        self.db = db
        self.collection = collection
    }

    func pipeline(upTo index: Int? = nil) throws -> [BValue] {
        let upto = index.map { $0 + 1 } ?? stages.count
        return try stages.prefix(upto).filter(\.enabled).map { try $0.value() }
    }

    var pipelineShell: String {
        let parts = stages.filter(\.enabled).compactMap { try? $0.value() }
        return BFormat.text(.array(parts))
    }

    func add(_ op: String = "$match", at: Int? = nil) {
        let s = PipelineStage(op: op, body: PipelineStage.template(op))
        if let at { stages.insert(s, at: at) } else { stages.append(s) }
    }

    func load(pipeline: [BValue]) {
        stages = pipeline.compactMap { v in
            guard let d = v.doc, let f = d.fields.first else { return nil }
            return PipelineStage(op: f.key, body: BFormat.text(f.value))
        }
    }

    func syncFromText() throws {
        load(pipeline: try ShellParser.parseArray(pipelineText))
    }

    /// Per-stage previews: the pipeline up to each stage, limited to a few docs.
    func refreshPreviews() async {
        for (i, s) in stages.enumerated() {
            guard s.enabled else { s.preview = []; continue }
            s.previewLoading = true
            defer { s.previewLoading = false }
            do {
                var p = try pipeline(upTo: i)
                if ["$out", "$merge"].contains(s.op) { s.previewError = "Writes are not previewed"; continue }
                p.append(.document(["$limit": 5]))
                let r = try await session.service.aggregate(db: db, collection: collection, pipeline: p, max: 5)
                s.preview = r.documents
                s.previewElapsed = r.elapsed
                s.previewError = nil
            } catch {
                s.preview = []
                s.previewError = error.localizedDescription
            }
        }
    }

    func run() async {
        if textMode { do { try syncFromText() } catch { self.error = error.localizedDescription; return } }
        running = true
        error = nil
        defer { running = false }
        do {
            let p = try pipeline()
            if p.contains(where: { $0.doc?.keys.first == "$out" || $0.doc?.keys.first == "$merge" }) && session.readOnly {
                error = "This connection is read-only."
                return
            }
            let r = try await session.service.aggregate(db: db, collection: collection, pipeline: p, max: 200)
            results = r.documents
            resultsElapsed = r.elapsed
            History.shared.record(namespace: "\(db).\(collection)", kind: "aggregate", filter: "", sort: "", project: "", pipeline: pipelineShell)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Schema

@MainActor @Observable
final class SchemaModel {
    let session: Session
    let db: String
    let collection: String
    var sampleSize = 1000
    var report: SchemaReport?
    var loading = false
    var error: String?
    var expanded: String?
    var insight: String?
    var insightBusy = false

    init(session: Session, db: String, collection: String) {
        self.session = session
        self.db = db
        self.collection = collection
    }

    func analyze() async {
        loading = true
        error = nil
        defer { loading = false }
        let t0 = Date()
        do {
            let docs = try await session.service.sample(db: db, collection: collection, size: sampleSize)
            let report = await Task.detached { SchemaAnalyzer.analyze(docs, elapsed: Date().timeIntervalSince(t0)) }.value
            self.report = report
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Indexes

@MainActor @Observable
final class IndexesModel {
    let session: Session
    let db: String
    let collection: String
    var indexes: [IndexInfo] = []
    var loading = false
    var error: String?
    var creating = false
    var newKeys = "{ field: 1 }"
    var newOptions = "{ }"
    var suggestions: [AISuggestion] = []
    var suggestBusy = false
    var suggestNote: String?

    init(session: Session, db: String, collection: String) {
        self.session = session
        self.db = db
        self.collection = collection
    }

    func load() async {
        loading = true
        defer { loading = false }
        do { indexes = try await session.service.indexes(db: db, collection: collection); error = nil } catch { self.error = error.localizedDescription }
    }

    func create(keys: String, options: String) async -> String? {
        guard !session.readOnly else { return "This connection is read-only." }
        do {
            try await session.service.createIndex(db: db, collection: collection, keys: try ShellParser.parseDocument(keys), options: try ShellParser.parseDocument(options))
            await load()
            return nil
        } catch { return error.localizedDescription }
    }

    func drop(_ name: String) async {
        guard !session.readOnly else { error = "This connection is read-only."; return }
        do { try await session.service.dropIndex(db: db, collection: collection, name: name); await load() } catch { self.error = error.localizedDescription }
    }
}

struct AISuggestion: Identifiable, Hashable {
    var id = UUID()
    var keys: String
    var options: String
    var reason: String
}

// MARK: - Explain

struct ExplainStage: Identifiable {
    var id = UUID()
    var stage: String
    var detail: String
    var nReturned: Int?
    var docsExamined: Int?
    var keysExamined: Int?
    var ms: Int?
    var children: [ExplainStage]
}

struct ExplainSummary {
    var root: ExplainStage?
    var nReturned: Int
    var docsExamined: Int
    var keysExamined: Int
    var ms: Int
    var indexes: [String]
    var collscan: Bool
    var sortInMemory: Bool
    var raw: BDoc
}

@MainActor @Observable
final class ExplainModel {
    let session: Session
    let db: String
    let collection: String
    var summary: ExplainSummary?
    var loading = false
    var error: String?
    var queryLabel = ""
    var analysis: String?
    var analysisBusy = false
    var showRaw = false

    init(session: Session, db: String, collection: String) {
        self.session = session
        self.db = db
        self.collection = collection
    }

    func run(query: FindQuery, label: String) async {
        loading = true
        error = nil
        analysis = nil
        queryLabel = label
        defer { loading = false }
        do {
            let raw = try await session.service.explainFind(db: db, collection: collection, query: query)
            summary = Self.summarize(raw)
        } catch { self.error = error.localizedDescription }
    }

    static func summarize(_ raw: BDoc) -> ExplainSummary {
        let stats = raw["executionStats"]?.doc ?? BDoc()
        let planner = raw["queryPlanner"]?.doc
        let execRoot = stats["executionStages"]?.doc ?? planner?["winningPlan"]?.doc
        var idx: [String] = []
        var collscan = false, sortMem = false
        func walk(_ d: BDoc) -> ExplainStage {
            var node = d
            if let qp = d["queryPlan"]?.doc { node = qp } // SBE plans wrap
            let st = node["stage"]?.stringValue ?? "?"
            if st == "COLLSCAN" { collscan = true }
            if st == "SORT" { sortMem = true }
            var detail = ""
            if let name = node["indexName"]?.stringValue {
                idx.append(name)
                detail = name
                if let kp = node["keyPattern"]?.doc { detail += "  " + BFormat.text(.document(kp), pretty: false) }
            } else if let f = node["filter"]?.doc, !f.isEmpty {
                detail = BFormat.text(.document(f), pretty: false)
            } else if let sp = node["sortPattern"]?.doc {
                detail = BFormat.text(.document(sp), pretty: false)
            }
            var kids: [BDoc] = []
            if let c = node["inputStage"]?.doc { kids.append(c) }
            for k in node["inputStages"]?.arrayValue ?? [] { if let c = k.doc { kids.append(c) } }
            return ExplainStage(stage: st, detail: detail, nReturned: node["nReturned"]?.number.map { Int($0) },
                                docsExamined: node["docsExamined"]?.number.map { Int($0) }, keysExamined: node["keysExamined"]?.number.map { Int($0) },
                                ms: node["executionTimeMillisEstimate"]?.number.map { Int($0) }, children: kids.map(walk))
        }
        let root = execRoot.map(walk)
        return ExplainSummary(root: root, nReturned: Int(stats["nReturned"]?.number ?? 0), docsExamined: Int(stats["totalDocsExamined"]?.number ?? 0),
                              keysExamined: Int(stats["totalKeysExamined"]?.number ?? 0), ms: Int(stats["executionTimeMillis"]?.number ?? 0),
                              indexes: idx, collscan: collscan, sortInMemory: sortMem, raw: raw)
    }
}

// MARK: - History

@MainActor @Observable
final class History {
    static let shared = History()
    var entries: [HistoryEntry] = Storage.load("history.json", as: [HistoryEntry].self) ?? []

    func record(namespace: String, kind: String, filter: String, sort: String, project: String, pipeline: String) {
        if filter.isEmpty && sort.isEmpty && project.isEmpty && pipeline.isEmpty { return }
        entries.removeAll { $0.namespace == namespace && $0.kind == kind && $0.filter == filter && $0.sort == sort && $0.project == project && $0.pipeline == pipeline && !$0.favorite }
        entries.insert(HistoryEntry(namespace: namespace, kind: kind, filter: filter, sort: sort, project: project, pipeline: pipeline, at: Date()), at: 0)
        if entries.count > 500 { entries.removeLast(entries.count - 500) }
        Storage.save(entries, "history.json")
    }

    func toggleFavorite(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].favorite.toggle()
        Storage.save(entries, "history.json")
    }

    func entries(for ns: String) -> [HistoryEntry] { entries.filter { $0.namespace == ns } }
}

struct ChangeEvent: Identifiable {
    let id = UUID()
    let op: String
    let at: Date
    let key: BValue?
    let fields: [String]
    let doc: BDoc?

    init(_ e: BDoc) {
        op = e["operationType"]?.stringValue ?? "?"
        if case .timestamp(let t, _) = e["clusterTime"] { at = Date(timeIntervalSince1970: TimeInterval(t)) } else { at = Date() }
        key = e["documentKey"]?.doc?["_id"]
        let upd = e["updateDescription"]?.doc
        fields = (upd?["updatedFields"]?.doc?.keys ?? []) + (upd?["removedFields"]?.arrayValue?.compactMap(\.stringValue).map { "−" + $0 } ?? [])
        doc = e["fullDocument"]?.doc
    }
}
