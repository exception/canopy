import Foundation
import MongoClient
import MongoCore
import MongoKitten

struct MongoCommandError: Error, LocalizedError {
    var message: String
    var code: Int?
    var codeName: String?
    var errorDescription: String? { codeName.map { "\($0): \(message)" } ?? message }
}

struct DatabaseInfo: Identifiable, Hashable {
    var name: String
    var sizeOnDisk: Double
    var empty: Bool
    var id: String { name }
}

struct CollectionInfo: Identifiable, Hashable {
    var name: String
    var type: String // collection | view | timeseries
    var count: Int?
    var size: Double?
    var storageSize: Double?
    var avgObjSize: Double?
    var indexCount: Int?
    var totalIndexSize: Double?
    var id: String { name }
    var isView: Bool { type == "view" }
}

struct FindQuery: Hashable {
    var filter = BDoc()
    var projection = BDoc()
    var sort = BDoc()
    var skip = 0
    var limit = 50
    var collation: BDoc? = nil
}

struct FindResult {
    var documents: [BDoc]
    var elapsed: TimeInterval
}

struct IndexInfo: Identifiable, Hashable {
    var name: String
    var keys: BDoc
    var unique: Bool
    var sparse: Bool
    var ttl: Int?
    var partial: BDoc?
    var hidden: Bool
    var size: Double?
    var ops: Int?
    var since: Date?
    var raw: BDoc
    var id: String { name }

    var kind: String {
        let vals = keys.fields.map(\.value)
        if vals.contains(.string("text")) { return "text" }
        if vals.contains(.string("2dsphere")) { return "2dsphere" }
        if vals.contains(.string("hashed")) { return "hashed" }
        if name == "_id_" { return "primary" }
        return keys.count > 1 ? "compound" : "single"
    }
}

struct ServerStatus {
    var version: String
    var host: String
    var uptime: Double
    var connections: Int
    var availableConnections: Int
    var opcounters: [String: Double]
    var bytesIn: Double
    var bytesOut: Double
    var residentMB: Double
    var storageEngine: String
    var replicaSet: String?
    var at: Date
}

/// One live connection to a deployment. Every operation is a raw database
/// command, so Canopy can do anything mongosh can, with the driver only
/// handling wire protocol, auth, TLS and topology.
final class MongoService: @unchecked Sendable {
    let cluster: MongoCluster
    let settings: ConnectionSettings
    private(set) var serverVersion: String = ""
    private(set) var isReplicaSet = false

    private init(cluster: MongoCluster, settings: ConnectionSettings) {
        self.cluster = cluster
        self.settings = settings
    }

    static func connect(uri: String) async throws -> MongoService {
        let settings = try ConnectionSettings(uri)
        let cluster = try await MongoCluster(connectingTo: settings)
        let svc = MongoService(cluster: cluster, settings: settings)
        if let info = try? await svc.command(["buildInfo": 1], db: "admin") {
            svc.serverVersion = info["version"]?.stringValue ?? ""
        }
        if let hello = try? await svc.command(["hello": 1], db: "admin") {
            svc.isReplicaSet = hello["setName"] != nil
        }
        return svc
    }

    func disconnect() async { await cluster.disconnect() }

    var defaultDatabase: String? { settings.targetDatabase }

    // MARK: Commands

    @discardableResult
    func command(_ cmd: BDoc, db: String) async throws -> BDoc {
        let conn = try await cluster.next(for: .writable)
        let reply = try await conn.execute(BSONBridge.document(cmd), namespace: MongoNamespace(to: "$cmd", inDatabase: db))
        let doc = BSONBridge.doc(try reply.getDocument())
        let ok = doc["ok"]?.number ?? 0
        if ok != 1 {
            throw MongoCommandError(message: doc["errmsg"]?.stringValue ?? "Command failed",
                                    code: doc["code"]?.number.map { Int($0) }, codeName: doc["codeName"]?.stringValue)
        }
        if let we = doc["writeErrors"]?.arrayValue?.first?.doc {
            throw MongoCommandError(message: we["errmsg"]?.stringValue ?? "Write failed", code: we["code"]?.number.map { Int($0) }, codeName: nil)
        }
        return doc
    }


    /// Runs a cursor command and drains up to `max` documents.
    func cursor(_ cmd: BDoc, db: String, max: Int) async throws -> [BDoc] {
        let first = try await command(cmd, db: db)
        guard let cur = first["cursor"]?.doc else { return [] }
        var docs = (cur["firstBatch"]?.arrayValue ?? []).compactMap(\.doc)
        var id = cur["id"] ?? .int64(0)
        let ns = cur["ns"]?.stringValue ?? ""
        let coll = ns.split(separator: ".", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        do {
            while docs.count < max, id.number ?? 0 != 0 {
                let more = try await command(BDoc([("getMore", id), ("collection", .string(coll)), ("batchSize", .int32(Int32(min(1000, max - docs.count))))]), db: db)
                guard let c = more["cursor"]?.doc else { break }
                docs += (c["nextBatch"]?.arrayValue ?? []).compactMap(\.doc)
                id = c["id"] ?? .int64(0)
            }
        } catch {
            if id.number ?? 0 != 0 { _ = try? await command(BDoc([("killCursors", .string(coll)), ("cursors", .array([id]))]), db: db) }
            throw error
        }
        if id.number ?? 0 != 0 {
            _ = try? await command(BDoc([("killCursors", .string(coll)), ("cursors", .array([id]))]), db: db)
        }
        return Array(docs.prefix(max))
    }

    // MARK: Metadata

    func listDatabases() async throws -> [DatabaseInfo] {
        let r = try await command(["listDatabases": 1], db: "admin")
        return (r["databases"]?.arrayValue ?? []).compactMap(\.doc).map {
            DatabaseInfo(name: $0["name"]?.stringValue ?? "?", sizeOnDisk: $0["sizeOnDisk"]?.number ?? 0, empty: $0["empty"] == .bool(true))
        }.sorted { $0.name < $1.name }
    }

    func listCollections(db: String) async throws -> [CollectionInfo] {
        let docs = try await cursor(BDoc([("listCollections", .int32(1)), ("cursor", .document(BDoc()))]), db: db, max: 10_000)
        return docs.map {
            CollectionInfo(name: $0["name"]?.stringValue ?? "?", type: $0["type"]?.stringValue ?? "collection")
        }.filter { !$0.name.hasPrefix("system.") }.sorted { $0.name < $1.name }
    }

    func collectionStats(db: String, collection: String) async throws -> CollectionInfo {
        let docs = try await cursor(BDoc([
            ("aggregate", .string(collection)),
            ("pipeline", .array([.document(BDoc([("$collStats", .document(BDoc([("storageStats", .document(BDoc()))])))]))])),
            ("cursor", .document(BDoc())),
        ]), db: db, max: 1)
        var info = CollectionInfo(name: collection, type: "collection")
        if let s = docs.first?["storageStats"]?.doc {
            info.count = s["count"]?.number.map { Int($0) }
            info.size = s["size"]?.number
            info.storageSize = s["storageSize"]?.number
            info.avgObjSize = s["avgObjSize"]?.number
            info.indexCount = s["nindexes"]?.number.map { Int($0) }
            info.totalIndexSize = s["totalIndexSize"]?.number
        }
        return info
    }

    // MARK: Reads

    func find(db: String, collection: String, query: FindQuery) async throws -> FindResult {
        let t0 = Date()
        var cmd = BDoc([("find", .string(collection)), ("filter", .document(query.filter))])
        if !query.projection.isEmpty { cmd["projection"] = .document(query.projection) }
        if !query.sort.isEmpty { cmd["sort"] = .document(query.sort) }
        if query.skip > 0 { cmd["skip"] = .int64(Int64(query.skip)) }
        cmd["limit"] = .int64(Int64(query.limit))
        cmd["batchSize"] = .int32(Int32(min(query.limit, 1000)))
        cmd["maxTimeMS"] = .int32(60_000)
        if let c = query.collation { cmd["collation"] = .document(c) }
        let docs = try await cursor(cmd, db: db, max: query.limit)
        return FindResult(documents: docs, elapsed: Date().timeIntervalSince(t0))
    }

    /// Exact count with a time cap; nil if it took too long.
    func count(db: String, collection: String, filter: BDoc, maxTimeMS: Int32 = 5000) async throws -> Int? {
        if filter.isEmpty {
            let r = try await command(BDoc([("count", .string(collection))]), db: db)
            return r["n"]?.number.map { Int($0) }
        }
        do {
            let r = try await command(BDoc([("count", .string(collection)), ("query", .document(filter)), ("maxTimeMS", .int32(maxTimeMS))]), db: db)
            return r["n"]?.number.map { Int($0) }
        } catch let e as MongoCommandError where e.code == 50 {
            return nil
        }
    }

    func aggregate(db: String, collection: String, pipeline: [BValue], max: Int = 50, allowDiskUse: Bool = true) async throws -> FindResult {
        let t0 = Date()
        var cmd = BDoc([("aggregate", .string(collection)), ("pipeline", .array(pipeline)), ("cursor", .document(BDoc([("batchSize", .int32(Int32(min(max, 1000))))])))])
        if allowDiskUse { cmd["allowDiskUse"] = .bool(true) }
        cmd["maxTimeMS"] = .int32(60_000)
        let docs = try await cursor(cmd, db: db, max: max)
        return FindResult(documents: docs, elapsed: Date().timeIntervalSince(t0))
    }

    func sample(db: String, collection: String, size: Int) async throws -> [BDoc] {
        try await aggregate(db: db, collection: collection, pipeline: [.document(BDoc([("$sample", .document(BDoc([("size", .int32(Int32(size)))])))]))], max: size).documents
    }

    func explainFind(db: String, collection: String, query: FindQuery) async throws -> BDoc {
        var inner = BDoc([("find", .string(collection)), ("filter", .document(query.filter))])
        if !query.projection.isEmpty { inner["projection"] = .document(query.projection) }
        if !query.sort.isEmpty { inner["sort"] = .document(query.sort) }
        if query.skip > 0 { inner["skip"] = .int64(Int64(query.skip)) }
        inner["limit"] = .int64(Int64(query.limit))
        return try await command(BDoc([("explain", .document(inner)), ("verbosity", .string("executionStats"))]), db: db)
    }

    func explainAggregate(db: String, collection: String, pipeline: [BValue]) async throws -> BDoc {
        let inner = BDoc([("aggregate", .string(collection)), ("pipeline", .array(pipeline)), ("cursor", .document(BDoc()))])
        return try await command(BDoc([("explain", .document(inner)), ("verbosity", .string("executionStats"))]), db: db)
    }

    // MARK: Change streams

    /// Tails a collection's change stream until cancelled.
    func watch(db: String, collection: String) -> AsyncThrowingStream<BDoc, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var id: BValue = .int64(0)
                do {
                    let first = try await command(BDoc([
                        ("aggregate", .string(collection)),
                        ("pipeline", .array([.document(["$changeStream": .document(["fullDocument": "updateLookup"])])])),
                        ("cursor", .document(BDoc())),
                    ]), db: db)
                    let cur = first["cursor"]?.doc ?? BDoc()
                    for d in (cur["firstBatch"]?.arrayValue ?? []).compactMap(\.doc) { cont.yield(d) }
                    id = cur["id"] ?? .int64(0)
                    while !Task.isCancelled, id.number ?? 0 != 0 {
                        let more = try await command(BDoc([("getMore", id), ("collection", .string(collection)), ("maxTimeMS", .int32(1000))]), db: db)
                        let c = more["cursor"]?.doc ?? BDoc()
                        for d in (c["nextBatch"]?.arrayValue ?? []).compactMap(\.doc) { cont.yield(d) }
                        id = c["id"] ?? .int64(0)
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
                if id.number ?? 0 != 0 { _ = try? await self.command(BDoc([("killCursors", .string(collection)), ("cursors", .array([id]))]), db: db) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Indexes

    func indexes(db: String, collection: String) async throws -> [IndexInfo] {
        let list = try await cursor(BDoc([("listIndexes", .string(collection)), ("cursor", .document(BDoc()))]), db: db, max: 1000)
        let stats = (try? await aggregate(db: db, collection: collection, pipeline: [.document(BDoc([("$indexStats", .document(BDoc()))]))], max: 1000).documents) ?? []
        let sizes = (try? await cursor(BDoc([
            ("aggregate", .string(collection)),
            ("pipeline", .array([.document(BDoc([("$collStats", .document(BDoc([("storageStats", .document(BDoc()))])))]))])),
            ("cursor", .document(BDoc())),
        ]), db: db, max: 1).first?["storageStats"]?.doc?["indexSizes"]?.doc) ?? BDoc()
        return list.map { d in
            let name = d["name"]?.stringValue ?? "?"
            let st = stats.first { $0["name"]?.stringValue == name }?["accesses"]?.doc
            return IndexInfo(name: name, keys: d["key"]?.doc ?? BDoc(), unique: d["unique"] == .bool(true), sparse: d["sparse"] == .bool(true),
                             ttl: d["expireAfterSeconds"]?.number.map { Int($0) }, partial: d["partialFilterExpression"]?.doc,
                             hidden: d["hidden"] == .bool(true), size: sizes[name]?.number,
                             ops: st?["ops"]?.number.map { Int($0) }, since: { if case .date(let dt) = st?["since"] { return dt }; return nil }(), raw: d)
        }
    }

    func createIndex(db: String, collection: String, keys: BDoc, options: BDoc) async throws {
        var spec = options
        spec["key"] = .document(keys)
        if spec["name"] == nil {
            spec["name"] = .string(keys.fields.map { "\($0.key)_\(BFormat.preview($0.value))" }.joined(separator: "_"))
        }
        try await command(BDoc([("createIndexes", .string(collection)), ("indexes", .array([.document(spec)]))]), db: db)
    }

    func dropIndex(db: String, collection: String, name: String) async throws {
        try await command(BDoc([("dropIndexes", .string(collection)), ("index", .string(name))]), db: db)
    }

    // MARK: Writes

    func insert(db: String, collection: String, docs: [BDoc]) async throws -> Int {
        let r = try await command(BDoc([("insert", .string(collection)), ("documents", .array(docs.map { .document($0) }))]), db: db)
        return Int(r["n"]?.number ?? 0)
    }

    func replace(db: String, collection: String, id: BValue, with doc: BDoc) async throws {
        let r = try await command(BDoc([("update", .string(collection)), ("updates", .array([.document(BDoc([
            ("q", .document(BDoc([("_id", id)]))), ("u", .document(doc)),
        ]))]))]), db: db)
        if r["n"]?.number == 0 { throw MongoCommandError(message: "No document with that _id anymore", code: nil, codeName: nil) }
    }

    func delete(db: String, collection: String, id: BValue) async throws {
        let r = try await command(BDoc([("delete", .string(collection)), ("deletes", .array([.document(BDoc([
            ("q", .document(BDoc([("_id", id)]))), ("limit", .int32(1)),
        ]))]))]), db: db)
        if r["n"]?.number == 0 { throw MongoCommandError(message: "That document was already deleted", code: nil, codeName: nil) }
    }

    /// `update` is an operator document ({$set: …}) or a pipeline array.
    func updateMany(db: String, collection: String, filter: BDoc, update: BValue) async throws -> (matched: Int, modified: Int) {
        let r = try await command(BDoc([("update", .string(collection)), ("updates", .array([.document(BDoc([
            ("q", .document(filter)), ("u", update), ("multi", .bool(true)),
        ]))]))]), db: db)
        return (Int(r["n"]?.number ?? 0), Int(r["nModified"]?.number ?? 0))
    }

    func deleteMany(db: String, collection: String, filter: BDoc) async throws -> Int {
        let r = try await command(BDoc([("delete", .string(collection)), ("deletes", .array([.document(BDoc([
            ("q", .document(filter)), ("limit", .int32(0)),
        ]))]))]), db: db)
        return Int(r["n"]?.number ?? 0)
    }

    func createCollection(db: String, name: String) async throws {
        try await command(BDoc([("create", .string(name))]), db: db)
    }

    func dropCollection(db: String, name: String) async throws {
        try await command(BDoc([("drop", .string(name))]), db: db)
    }

    // MARK: Server

    func serverStatus() async throws -> ServerStatus {
        let s = try await command(["serverStatus": 1], db: "admin")
        let conns = s["connections"]?.doc
        let ops = s["opcounters"]?.doc ?? BDoc()
        var counters: [String: Double] = [:]
        for f in ops.fields { counters[f.key] = f.value.number ?? 0 }
        return ServerStatus(version: s["version"]?.stringValue ?? serverVersion, host: s["host"]?.stringValue ?? "",
                            uptime: s["uptime"]?.number ?? 0, connections: Int(conns?["current"]?.number ?? 0),
                            availableConnections: Int(conns?["available"]?.number ?? 0), opcounters: counters,
                            bytesIn: s["network"]?.doc?["bytesIn"]?.number ?? 0, bytesOut: s["network"]?.doc?["bytesOut"]?.number ?? 0,
                            residentMB: s["mem"]?.doc?["resident"]?.number ?? 0,
                            storageEngine: s["storageEngine"]?.doc?["name"]?.stringValue ?? "",
                            replicaSet: s["repl"]?.doc?["setName"]?.stringValue, at: Date())
    }

    func currentOps() async throws -> [BDoc] {
        let r = try await command(BDoc([("currentOp", .int32(1)), ("active", .bool(true))]), db: "admin")
        return (r["inprog"]?.arrayValue ?? []).compactMap(\.doc)
    }

    func killOp(_ opid: BValue) async throws {
        try await command(BDoc([("killOp", .int32(1)), ("op", opid)]), db: "admin")
    }
}

extension BDoc: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, BValue)...) { self.init(elements.map { ($0.0, $0.1) }) }
}

extension BValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral {
    init(integerLiteral value: Int32) { self = .int32(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .double(value) }
}
