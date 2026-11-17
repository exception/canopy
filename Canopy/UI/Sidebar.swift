import SwiftUI

struct Sidebar: View {
    @Environment(AppState.self) private var app
    @State private var filter = ""
    @State private var newCollectionDB: String?
    @State private var newCollectionName = ""

    var body: some View {
        VStack(spacing: 0) {
            if let s = app.session {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(Color.cText3)
                    TextField("Filter", text: $filter).textFieldStyle(.plain).font(.system(size: 12.5))
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color.cField, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.cHairline))
                .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        SidebarRow(icon: "server.rack", title: "Server overview", selected: app.currentTab?.kind == .server) { app.openServer() }
                            .padding(.bottom, 6)
                        Text("DATABASES").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Color.cText3)
                            .padding(.horizontal, 12).padding(.bottom, 3)
                        // One flat list of uniform rows so only what's on screen is built. Nesting every
                        // collection inside its database row made a 150-collection db a single huge lazy item.
                        ForEach(treeRows(s)) { row in
                            switch row.kind {
                            case .database(let db, let open):
                                DatabaseRow(session: s, db: db, open: open, loading: s.loadingDBs.contains(db.name)) { newCollectionDB = db.name }
                            case .collection(let db, let c, let selected, let count):
                                CollectionRow(session: s, db: db, coll: c, selected: selected, count: count)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)

                Divider()
                HStack(spacing: 8) {
                    Circle().fill(Color(ns: Theme.hex(s.saved.color))).frame(width: 7, height: 7)
                    Text(s.saved.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Button { Task { await s.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh")
                    Button { Task { await app.disconnect() } } label: { Image(systemName: "eject") }.buttonStyle(.borderless).help("Disconnect")
                }
                .font(.system(size: 12))
                .foregroundStyle(Color.cText2)
                .padding(.horizontal, 12).padding(.vertical, 9)
            } else {
                ConnectionList()
            }
        }
        .background(Color(ns: Theme.sidebar))
        .alert("New collection in \(newCollectionDB ?? "")", isPresented: Binding(get: { newCollectionDB != nil }, set: { if !$0 { newCollectionDB = nil } })) {
            TextField("Name", text: $newCollectionName)
            Button("Create") {
                let (db, n) = (newCollectionDB ?? "", newCollectionName)
                newCollectionName = ""
                guard let s = app.session, !db.isEmpty, !n.isEmpty else { return }
                Task { try? await s.service.createCollection(db: db, name: n); await s.loadCollections(db) }
            }
            Button("Cancel", role: .cancel) { newCollectionName = "" }
        }
    }

    struct TreeRow: Identifiable {
        enum Kind { case database(DatabaseInfo, open: Bool), collection(String, CollectionInfo, selected: Bool, count: Int?) }
        let id: String
        let kind: Kind
    }

    private func treeRows(_ s: Session) -> [TreeRow] {
        var rows: [TreeRow] = []
        let current = app.currentTab?.kind
        for db in s.databases {
            let all = s.collections[db.name] ?? []
            let colls = filter.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            guard filter.isEmpty || !colls.isEmpty || db.name.localizedCaseInsensitiveContains(filter) else { continue }
            let open = s.expanded.contains(db.name) || (!filter.isEmpty && !colls.isEmpty)
            rows.append(TreeRow(id: "d:" + db.name, kind: .database(db, open: open)))
            guard open else { continue }
            for c in colls {
                rows.append(TreeRow(id: "c:\(db.name).\(c.name)", kind: .collection(db.name, c,
                    selected: current == .collection(db: db.name, name: c.name), count: s.stats["\(db.name).\(c.name)"]?.count)))
            }
        }
        return rows
    }
}

struct SidebarRow: View {
    var icon: String
    var title: String
    var selected = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(selected ? Color.cAccent : Color.cText2).frame(width: 16)
            Text(title).font(.system(size: 12.5, weight: selected ? .semibold : .regular))
            Spacer()
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(selected ? Color(ns: Theme.selection) : (hover ? Color(ns: Theme.hover) : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hover = $0 }
    }
}

struct DatabaseRow: View {
    let session: Session
    let db: DatabaseInfo
    let open: Bool
    let loading: Bool
    var onNewCollection: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.cText3)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                .animation(.snappy(duration: 0.15), value: open)
            Image(systemName: "cylinder.split.1x2").font(.system(size: 11.5)).foregroundStyle(Color.cText2)
            Text(db.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Spacer()
            if loading { ProgressView().controlSize(.mini) }
            Text(Fmt.bytes(db.sizeOnDisk)).font(.system(size: 10.5)).foregroundStyle(Color.cText3).opacity(hover ? 1 : 0.7)
        }
        .padding(.horizontal, 6).frame(height: 26)
        .background(hover ? Color(ns: Theme.hover) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { session.toggle(db.name) }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Refresh") { Task { await session.loadCollections(db.name) } }
            if !session.readOnly { Button("New Collection…", action: onNewCollection) }
        }
    }
}

struct CollectionRow: View {
    @Environment(AppState.self) private var app
    let session: Session
    let db: String
    let coll: CollectionInfo
    /// Plain values from the parent, so a row only re-renders when its own selection or count changes.
    let selected: Bool
    let count: Int?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: coll.isView ? "eye" : "square.stack.3d.up").font(.system(size: 10.5))
                .foregroundStyle(selected ? Color.cAccent : Color.cText3).frame(width: 14)
            Text(coll.name).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 4)
            if let n = count {
                Text(Fmt.compact(n)).font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.cText3)
            }
        }
        .padding(.leading, 28).padding(.trailing, 8).frame(height: 25)
        .background(selected ? Color(ns: Theme.selection) : (hover ? Color(ns: Theme.hover) : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { app.open(db: db, collection: coll.name) }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Open in New Tab") { app.open(db: db, collection: coll.name, newTab: true) }
            Button("Analyze Schema") { app.open(db: db, collection: coll.name).mode = .schema }
            Button("Indexes") { app.open(db: db, collection: coll.name).mode = .indexes }
            Divider()
            Button("Copy Name") { app.copy(coll.name) }
            Button("Copy Namespace") { app.copy("\(db).\(coll.name)") }
            if !session.readOnly {
                Divider()
                Button("Drop Collection…", role: .destructive) { confirmDrop() }
            }
        }
    }

    private func confirmDrop() {
        let a = NSAlert()
        a.messageText = "Drop \(db).\(coll.name)?"
        a.informativeText = "This deletes every document and index in the collection. It can't be undone."
        a.alertStyle = .critical
        a.addButton(withTitle: "Drop")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            Task {
                guard await session.authorize("drop the collection \(db).\(coll.name)") else { return }
                try? await session.service.dropCollection(db: db, name: coll.name)
                if let t = app.tabs.first(where: { $0.kind == .collection(db: db, name: coll.name) }) { app.close(t.id) }
                await session.loadCollections(db)
            }
        }
    }
}
