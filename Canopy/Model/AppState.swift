import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    var connections: [SavedConnection] = Storage.load("connections.json", as: [SavedConnection].self) ?? []
    var session: Session?
    var connecting: UUID?
    var connectError: String?

    var tabs: [WorkspaceTab] = []
    var currentTabID: UUID?

    var showPalette = false
    var showCopilot = false
    var editingConnection: SavedConnection?
    var showInspector = true
    var toast: String?

    let copilot = CopilotModel()

    init() {
        copilot.app = self
        ToolServer.shared.app = self
        if connections.isEmpty {
            // First run: offer localhost.
            connections = [SavedConnection(name: "Local", uri: "mongodb://localhost:27017/?directConnection=true", color: 0x3DD68C)]
        }
    }

    var currentTab: WorkspaceTab? { tabs.first { $0.id == currentTabID } }

    func saveConnections() { Storage.save(connections, "connections.json") }

    func upsert(_ c: SavedConnection, password: String?) {
        if let i = connections.firstIndex(where: { $0.id == c.id }) { connections[i] = c } else { connections.append(c) }
        if let password { Keychain.set(password, for: c.id) }
        saveConnections()
    }

    func remove(_ c: SavedConnection) {
        connections.removeAll { $0.id == c.id }
        Keychain.set(nil, for: c.id)
        saveConnections()
    }

    func connect(_ c: SavedConnection) async {
        connecting = c.id
        connectError = nil
        defer { connecting = nil }
        do {
            let uri = ConnectionString.join(c.uri, password: Keychain.get(c.id))
            let svc = try await MongoService.connect(uri: uri)
            if let old = session { await old.service.disconnect() }
            let s = Session(saved: c, service: svc)
            session = s
            tabs = []
            currentTabID = nil
            copilot.reset()
            if let i = connections.firstIndex(where: { $0.id == c.id }) { connections[i].lastUsed = Date(); saveConnections() }
            await s.refresh()
            // Expand the user databases so the tree isn't empty.
            for db in s.databases.prefix(3) where !["admin", "config", "local"].contains(db.name) { s.toggle(db.name) }
        } catch {
            connectError = "\(c.name): \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        guard let s = session else { return }
        session = nil
        tabs = []
        currentTabID = nil
        copilot.reset()
        await s.service.disconnect()
    }

    @discardableResult
    func open(db: String, collection: String, newTab: Bool = false) -> WorkspaceTab {
        if !newTab, let t = tabs.first(where: { $0.kind == .collection(db: db, name: collection) }) {
            currentTabID = t.id
            return t
        }
        let t = WorkspaceTab(kind: .collection(db: db, name: collection), session: session!)
        if let cur = currentTab, let i = tabs.firstIndex(where: { $0.id == cur.id }) { tabs.insert(t, at: i + 1) } else { tabs.append(t) }
        currentTabID = t.id
        Task { await t.docs.run(record: false) }
        return t
    }

    func openServer() {
        if let t = tabs.first(where: { $0.kind == .server }) { currentTabID = t.id; return }
        guard let session else { return }
        let t = WorkspaceTab(kind: .server, session: session)
        tabs.insert(t, at: 0)
        currentTabID = t.id
    }

    func close(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if currentTabID == id { currentTabID = tabs.indices.contains(i) ? tabs[i].id : tabs.last?.id }
    }

    func selectTab(offset: Int) {
        guard let cur = currentTab, let i = tabs.firstIndex(where: { $0.id == cur.id }), !tabs.isEmpty else { return }
        currentTabID = tabs[(i + offset + tabs.count) % tabs.count].id
    }

    func flash(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if toast == text { toast = nil }
        }
    }

    func copy(_ text: String, label: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(label)
    }
}
