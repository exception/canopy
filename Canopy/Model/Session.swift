import Foundation
import Observation

/// A live connection and its database/collection tree.
@MainActor @Observable
final class Session {
    let saved: SavedConnection
    let service: MongoService
    var databases: [DatabaseInfo] = []
    var collections: [String: [CollectionInfo]] = [:]
    var stats: [String: CollectionInfo] = [:]
    var expanded: Set<String> = []
    var loadingDBs: Set<String> = []
    var error: String?

    init(saved: SavedConnection, service: MongoService) {
        self.saved = saved
        self.service = service
    }

    var readOnly: Bool { saved.readOnly }
    /// Read live from the saved list so toggling it in the editor applies without reconnecting.
    var isProduction: Bool { AppState.shared.connections.first { $0.id == saved.id }?.isProduction ?? saved.isProduction }

    /// Gate for big changes. Non-production connections pass straight through; production asks
    /// for Touch ID or the account password. `action` completes "Canopy is trying to …".
    func authorize(_ action: String) async -> Bool {
        guard isProduction else { return true }
        let ok = await ProductionGuard.authorize("\(action) on \(saved.name)")
        if !ok { AppState.shared.flash("Not authorized. Nothing was changed.") }
        return ok
    }

    func refresh() async {
        do {
            let dbs = try await service.listDatabases()
            databases = dbs.filter { !["admin", "config", "local"].contains($0.name) } + dbs.filter { ["admin", "config", "local"].contains($0.name) }
            for db in expanded { await loadCollections(db) }
        } catch {
            // Users without listDatabases rights still get their default db.
            if let def = service.defaultDatabase { databases = [DatabaseInfo(name: def, sizeOnDisk: 0, empty: false)] }
            self.error = error.localizedDescription
        }
    }

    func toggle(_ db: String) {
        if expanded.contains(db) { expanded.remove(db) } else {
            expanded.insert(db)
            // Already listed: just show it. Refresh (sidebar footer or context menu) reloads.
            if collections[db] == nil { Task { await loadCollections(db) } }
        }
    }

    func loadCollections(_ db: String) async {
        loadingDBs.insert(db)
        defer { loadingDBs.remove(db) }
        guard let list = try? await service.listCollections(db: db) else { return }
        collections[db] = list
        // Stats with bounded concurrency, applied in batches: one `stats` write per result made the
        // whole sidebar re-render ~150 times while it was being scrolled.
        let names = list.filter { !$0.isView }.map(\.name)
        var pending: [String: CollectionInfo] = [:]
        func flush() {
            guard !pending.isEmpty else { return }
            var next = stats
            next.merge(pending) { $1 }
            stats = next
            pending.removeAll()
        }
        await withTaskGroup(of: CollectionInfo?.self) { group in
            var it = names.makeIterator()
            for _ in 0..<8 { if let n = it.next() { group.addTask { [service] in try? await service.collectionStats(db: db, collection: n) } } }
            for await s in group {
                if let s { pending["\(db).\(s.name)"] = s }
                if pending.count >= 25 { flush() }
                if let n = it.next() { group.addTask { [service] in try? await service.collectionStats(db: db, collection: n) } }
            }
        }
        flush()
    }

    func stat(_ db: String, _ coll: String) -> CollectionInfo? { stats["\(db).\(coll)"] }

    func refreshStat(_ db: String, _ coll: String) async {
        if let s = try? await service.collectionStats(db: db, collection: coll) { stats["\(db).\(coll)"] = s }
    }

    var allNamespaces: [(String, String)] {
        databases.flatMap { db in (collections[db.name] ?? []).map { (db.name, $0.name) } }
    }
}
