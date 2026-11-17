import SwiftUI

struct Sidebar: View {
    @Environment(AppState.self) private var app
    @State private var filter = ""

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
                        ForEach(s.databases) { db in
                            DatabaseRow(session: s, db: db, filter: filter)
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
    @Environment(AppState.self) private var app
    let session: Session
    let db: DatabaseInfo
    let filter: String
    @State private var hover = false
    @State private var newCollection: String?

    var collections: [CollectionInfo] {
        let all = session.collections[db.name] ?? []
        return filter.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        let open = session.expanded.contains(db.name) || (!filter.isEmpty && !collections.isEmpty)
        if filter.isEmpty || !collections.isEmpty || db.name.localizedCaseInsensitiveContains(filter) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.cText3)
                        .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                    Image(systemName: "cylinder.split.1x2").font(.system(size: 11.5)).foregroundStyle(Color.cText2)
                    Text(db.name).font(.system(size: 12.5, weight: .medium))
                    Spacer()
                    if session.loadingDBs.contains(db.name) { ProgressView().controlSize(.mini) }
                    Text(Fmt.bytes(db.sizeOnDisk)).font(.system(size: 10.5)).foregroundStyle(Color.cText3).opacity(hover ? 1 : 0.7)
                }
                .padding(.horizontal, 6).frame(height: 26)
                .background(hover ? Color(ns: Theme.hover) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.snappy(duration: 0.18)) { session.toggle(db.name) } }
                .onHover { hover = $0 }
                .contextMenu {
                    Button("Refresh") { Task { await session.loadCollections(db.name) } }
                    if !session.readOnly { Button("New Collection…") { newCollection = "" } }
                }
                if open {
                    ForEach(collections) { c in CollectionRow(session: session, db: db.name, coll: c) }
                }
            }
            .alert("New collection in \(db.name)", isPresented: Binding(get: { newCollection != nil }, set: { if !$0 { newCollection = nil } })) {
                TextField("Name", text: Binding(get: { newCollection ?? "" }, set: { newCollection = $0 }))
                Button("Create") {
                    let n = newCollection ?? ""
                    Task { try? await session.service.createCollection(db: db.name, name: n); await session.loadCollections(db.name) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct CollectionRow: View {
    @Environment(AppState.self) private var app
    let session: Session
    let db: String
    let coll: CollectionInfo
    @State private var hover = false

    var body: some View {
        let selected = app.currentTab?.kind == .collection(db: db, name: coll.name)
        let st = session.stat(db, coll.name)
        HStack(spacing: 6) {
            Image(systemName: coll.isView ? "eye" : "square.stack.3d.up").font(.system(size: 10.5))
                .foregroundStyle(selected ? Color.cAccent : Color.cText3).frame(width: 14)
            Text(coll.name).font(.system(size: 12.5, weight: selected ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 4)
            if let n = st?.count {
                Text(Fmt.compact(n)).font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.cText3)
            }
        }
        .padding(.leading, 28).padding(.trailing, 8).frame(height: 25)
        .background(selected ? Color(ns: Theme.selection) : (hover ? Color(ns: Theme.hover) : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { app.open(db: db, collection: coll.name) }
        .onHover { hover = $0 }
        .help(st.map { "\(Fmt.count($0.count)) documents · \(Fmt.bytes($0.size)) · \($0.indexCount ?? 0) indexes" } ?? coll.name)
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
                try? await session.service.dropCollection(db: db, name: coll.name)
                if let t = app.tabs.first(where: { $0.kind == .collection(db: db, name: coll.name) }) { app.close(t.id) }
                await session.loadCollections(db)
            }
        }
    }
}
