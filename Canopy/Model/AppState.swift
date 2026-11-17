import AppKit
import Foundation
import Observation

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    var connections: [SavedConnection] = Storage.load("connections.json", as: [SavedConnection].self) ?? []
    var folders: [ConnectionFolder] = Storage.load("folders.json", as: [ConnectionFolder].self) ?? []
    /// Open tabs per connection id.
    private var workspaces: [String: SavedWorkspace] = Storage.load("workspaces.json", as: [String: SavedWorkspace].self) ?? [:]
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
            if let old = session { saveWorkspace(); stopAllLive(); await old.service.disconnect() }
            let s = Session(saved: c, service: svc)
            session = s
            tabs = []
            currentTabID = nil
            copilot.reset()
            if let i = connections.firstIndex(where: { $0.id == c.id }) { connections[i].lastUsed = Date(); saveConnections() }
            await s.refresh()
            // Expand the user databases so the tree isn't empty.
            for db in s.databases.prefix(3) where !["admin", "config", "local"].contains(db.name) { s.toggle(db.name) }
            restoreWorkspace(for: c)
        } catch {
            connectError = "\(c.name): \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        guard let s = session else { return }
        saveWorkspace()
        stopAllLive()
        session = nil
        tabs = []
        currentTabID = nil
        copilot.reset()
        await s.service.disconnect()
    }

    // MARK: Folders

    func saveFolders() { Storage.save(folders, "folders.json") }

    @discardableResult
    func newFolder(_ name: String = "New Folder") -> ConnectionFolder {
        let palette: [UInt32] = [0x7AA2F7, 0xBB9AF7, 0x3DD68C, 0xF5A524, 0xFF5D5D, 0x2AC3DE]
        let f = ConnectionFolder(name: name, color: palette[folders.count % palette.count])
        folders.append(f)
        saveFolders()
        return f
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        folders[i].name = name.trimmingCharacters(in: .whitespaces)
        saveFolders()
    }

    func recolorFolder(_ id: UUID, _ color: UInt32) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].color = color
        saveFolders()
    }

    func toggleFolder(_ id: UUID) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].collapsed.toggle()
        saveFolders()
    }

    /// Deleting a folder keeps its connections; they move back to the unfiled list.
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for i in connections.indices where connections[i].folderID == id { connections[i].folderID = nil }
        saveFolders()
        saveConnections()
    }

    func move(_ connectionID: UUID, to folder: UUID?) {
        guard let i = connections.firstIndex(where: { $0.id == connectionID }), connections[i].folderID != folder else { return }
        connections[i].folderID = folder
        if let folder, let f = folders.firstIndex(where: { $0.id == folder }) { folders[f].collapsed = false; saveFolders() }
        saveConnections()
    }

    func connections(in folder: UUID?) -> [SavedConnection] {
        let known = Set(folders.map(\.id))
        return connections
            .filter { folder == nil ? ($0.folderID.map { !known.contains($0) } ?? true) : $0.folderID == folder }
            .sorted { ($0.favorite ? 0 : 1, $0.name.lowercased()) < ($1.favorite ? 0 : 1, $1.name.lowercased()) }
    }

    // MARK: Workspace restore

    func saveWorkspace() {
        guard let s = session else { return }
        let tabs = self.tabs.map { t in
            t.kind == .server ? SavedWorkspace.Tab(server: true, mode: t.mode.rawValue)
                              : SavedWorkspace.Tab(db: t.db, collection: t.collection, mode: t.mode.rawValue, view: t.docs.view.rawValue)
        }
        workspaces[s.saved.id.uuidString] = SavedWorkspace(tabs: tabs, current: self.tabs.firstIndex { $0.id == currentTabID })
        Storage.save(workspaces, "workspaces.json")
    }

    private func restoreWorkspace(for c: SavedConnection) {
        guard let w = workspaces[c.id.uuidString], !w.tabs.isEmpty else { return }
        for t in w.tabs {
            if t.server { openServer() }
            else if let db = t.db, let coll = t.collection {
                let tab = open(db: db, collection: coll, newTab: true)
                tab.mode = WorkspaceMode(rawValue: t.mode) ?? .documents
                if let v = t.view.flatMap(DocViewMode.init(rawValue:)) { tab.docs.view = v }
            }
        }
        if let i = w.current, tabs.indices.contains(i) { currentTabID = tabs[i].id }
    }

    private func stopAllLive() { for t in tabs { t.docs.stopLive() } }

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
        tabs[i].docs.stopLive()
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
