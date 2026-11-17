import SwiftUI

/// Sidebar list of saved connections (when disconnected), grouped into folders.
struct ConnectionList: View {
    @Environment(AppState.self) private var app
    @State private var renaming: UUID?
    @State private var unfiledTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("CONNECTIONS").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Color.cText3)
                Spacer()
                Button { renaming = app.newFolder().id } label: { Image(systemName: "folder.badge.plus").font(.system(size: 12)) }
                    .buttonStyle(.borderless).foregroundStyle(Color.cText3).help("New folder")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(app.folders) { f in
                        FolderSection(folder: f, renaming: $renaming)
                    }
                    let unfiled = app.connections(in: nil)
                    VStack(spacing: 1) {
                        ForEach(unfiled) { c in ConnectionRow(c: c) }
                        if unfiled.isEmpty && !app.folders.isEmpty {
                            Text("Drop here to take out of a folder").font(.system(size: 11)).foregroundStyle(Color.cText3)
                                .frame(maxWidth: .infinity).padding(.vertical, 10).opacity(unfiledTargeted ? 1 : 0.6)
                        }
                    }
                    .padding(.top, app.folders.isEmpty ? 0 : 6)
                    .background(unfiledTargeted ? Color.cAccent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .dropDestination(for: String.self) { ids, _ in
                        ids.compactMap(UUID.init).forEach { id in withAnimation(.snappy) { app.move(id, to: nil) } }
                        return true
                    } isTargeted: { unfiledTargeted = $0 }
                }
                .padding(.horizontal, 6)
            }
            Spacer(minLength: 0)
            Button { app.editingConnection = SavedConnection(name: "", uri: "mongodb://localhost:27017") } label: {
                Label("New connection", systemImage: "plus").font(.system(size: 12.5))
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
    }
}

/// One folder: a header that collapses with a spring, and its connections.
struct FolderSection: View {
    @Environment(AppState.self) private var app
    let folder: ConnectionFolder
    @Binding var renaming: UUID?
    @State private var name = ""
    @State private var targeted = false
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        let items = app.connections(in: folder.id)
        VStack(spacing: 1) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.cText3)
                    .rotationEffect(.degrees(folder.collapsed ? 0 : 90))
                Image(systemName: folder.collapsed ? "folder.fill" : "folder").font(.system(size: 12.5))
                    .foregroundStyle(Color(ns: Theme.hex(folder.color)))
                    .contentTransition(.symbolEffect(.replace))
                if renaming == folder.id {
                    TextField("Folder name", text: $name).textFieldStyle(.plain).font(.system(size: 12.5, weight: .semibold))
                        .focused($focused)
                        .onSubmit { commit() }
                        .onExitCommand { renaming = nil }
                        .onAppear { name = folder.name; DispatchQueue.main.async { focused = true } }
                        .onChange(of: focused) { _, f in if !f { commit() } }
                } else {
                    Text(folder.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                Spacer()
                Text("\(items.count)").font(.system(size: 10.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.cText3)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.cPill, in: Capsule())
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(targeted ? Color(ns: Theme.hex(folder.color, 0.18)) : hover ? Color(ns: Theme.hover) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if targeted { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color(ns: Theme.hex(folder.color)), lineWidth: 1.5) }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { app.toggleFolder(folder.id) } }
            .onHover { hover = $0 }
            .contextMenu {
                Button("Rename…") { renaming = folder.id }
                Menu("Color") {
                    ForEach(Theme.connectionColors, id: \.1) { n, hex in Button(n) { app.recolorFolder(folder.id, hex) } }
                }
                Button("New Connection in Folder…") {
                    var c = SavedConnection(name: "", uri: "mongodb://localhost:27017"); c.folderID = folder.id
                    app.editingConnection = c
                }
                Divider()
                Button("Delete Folder (keeps connections)", role: .destructive) { withAnimation(.snappy) { app.deleteFolder(folder.id) } }
            }
            .dropDestination(for: String.self) { ids, _ in
                ids.compactMap(UUID.init).forEach { id in withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { app.move(id, to: folder.id) } }
                return true
            } isTargeted: { t in withAnimation(.easeOut(duration: 0.12)) { targeted = t } }

            if !folder.collapsed {
                VStack(spacing: 1) {
                    ForEach(items) { c in ConnectionRow(c: c).padding(.leading, 14) }
                    if items.isEmpty {
                        Text("Drag connections here").font(.system(size: 11)).foregroundStyle(Color.cText3)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 36).padding(.vertical, 6)
                    }
                }
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
            }
        }
        .clipped()
    }

    private func commit() {
        guard renaming == folder.id else { return }
        app.renameFolder(folder.id, to: name)
        renaming = nil
    }
}

struct ConnectionRow: View {
    @Environment(AppState.self) private var app
    let c: SavedConnection
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 3).fill(Color(ns: Theme.hex(c.color))).frame(width: 4, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(c.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if c.favorite { Image(systemName: "star.fill").font(.system(size: 8.5)).foregroundStyle(Color.cAmber) }
                    if c.isProduction { ProdBadge(small: true) }
                    if c.readOnly { Image(systemName: "lock.fill").font(.system(size: 8.5)).foregroundStyle(Color.cText3) }
                }
                Text(c.host).font(.system(size: 11)).foregroundStyle(Color.cText3).lineLimit(1)
            }
            Spacer()
            if app.connecting == c.id { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(hover ? Color(ns: Theme.hover) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { Task { await app.connect(c) } }
        .onHover { hover = $0 }
        .draggable(c.id.uuidString) {
            HStack(spacing: 6) {
                Circle().fill(Color(ns: Theme.hex(c.color))).frame(width: 8, height: 8)
                Text(c.name).font(.system(size: 12.5, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6).background(Color.cRaised, in: Capsule())
        }
        .contextMenu {
            Button("Connect") { Task { await app.connect(c) } }
            Button("Edit…") { app.editingConnection = c }
            Button(c.favorite ? "Unfavorite" : "Favorite") { var x = c; x.favorite.toggle(); app.upsert(x, password: nil) }
            Button("Duplicate") { var x = c; x.id = UUID(); x.name += " copy"; app.upsert(x, password: Keychain.get(c.id)) }
            FolderMenu(c: c)
            Divider()
            Button("Delete", role: .destructive) { app.remove(c) }
        }
    }
}

/// "Move to Folder" submenu shared by connection rows.
struct FolderMenu: View {
    @Environment(AppState.self) private var app
    let c: SavedConnection
    var body: some View {
        Menu("Move to Folder") {
            ForEach(app.folders) { f in
                Button(f.name) { withAnimation(.snappy) { app.move(c.id, to: f.id) } }.disabled(c.folderID == f.id)
            }
            if !app.folders.isEmpty { Divider() }
            Button("New Folder…") { let f = app.newFolder(); withAnimation(.snappy) { app.move(c.id, to: f.id) } }
            if c.folderID != nil { Button("Remove from Folder") { withAnimation(.snappy) { app.move(c.id, to: nil) } } }
        }
    }
}

/// Main area when disconnected: a welcoming list of connections.
struct ConnectView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "leaf.fill").font(.system(size: 26)).foregroundStyle(Color.cAccent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Canopy").font(.system(size: 24, weight: .bold))
                        Text("A fast, native home for your MongoDB data.").font(.system(size: 13)).foregroundStyle(Color.cText2)
                    }
                }
                let groups: [(ConnectionFolder?, [SavedConnection])] =
                    app.folders.map { ($0, app.connections(in: $0.id)) }.filter { !$0.1.isEmpty } + [(nil, app.connections(in: nil))]
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups.filter { !$0.1.isEmpty }, id: \.0?.id) { folder, items in
                            VStack(alignment: .leading, spacing: 6) {
                                if let folder {
                                    Label(folder.name.uppercased(), systemImage: "folder.fill")
                                        .font(.system(size: 10.5, weight: .semibold)).tracking(0.5)
                                        .foregroundStyle(Color(ns: Theme.hex(folder.color)))
                                        .padding(.leading, 4)
                                } else if groups.count > 1 {
                                    Text("OTHER").font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(Color.cText3).padding(.leading, 4)
                                }
                                VStack(spacing: 0) {
                                    ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                                        if i > 0 { Divider().padding(.leading, 56) }
                                        BigConnectionRow(c: c)
                                    }
                                }
                                .card(12)
                            }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 520)
                .fixedSize(horizontal: false, vertical: true)
                if let e = app.connectError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Color.cRed).textSelection(.enabled)
                }
                HStack {
                    Button { app.editingConnection = SavedConnection(name: "", uri: "mongodb://localhost:27017") } label: {
                        Label("New connection", systemImage: "plus")
                    }
                    .controlSize(.large)
                    Spacer()
                    Text("Paste a connection string with ⌘V").font(.system(size: 11.5)).foregroundStyle(Color.cText3)
                }
            }
            .frame(width: 520)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPasteCommand(of: [.plainText]) { providers in
            _ = providers.first?.loadObject(ofClass: NSString.self) { s, _ in
                guard let s = s as? String, s.hasPrefix("mongodb") else { return }
                Task { @MainActor in
                    let (uri, _) = ConnectionString.split(s)
                    app.editingConnection = SavedConnection(name: "", uri: s.trimmingCharacters(in: .whitespacesAndNewlines) == uri ? uri : s)
                }
            }
        }
    }
}

struct BigConnectionRow: View {
    @Environment(AppState.self) private var app
    let c: SavedConnection
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(ns: Theme.hex(c.color, 0.16))).frame(width: 30, height: 30)
                Image(systemName: c.isSRV ? "cloud" : "server.rack").font(.system(size: 13)).foregroundStyle(Color(ns: Theme.hex(c.color)))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(c.name).font(.system(size: 13.5, weight: .semibold))
                    if c.isProduction { ProdBadge(small: true) }
                    if c.readOnly { Text("READ-ONLY").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.cAmber) }
                }
                Text(c.username.map { "\($0) @ \(c.host)" } ?? c.host).font(.system(size: 11.5)).foregroundStyle(Color.cText3)
            }
            Spacer()
            if let d = c.lastUsed { Text(d, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(Color.cText3) }
            if app.connecting == c.id { ProgressView().controlSize(.small) }
            else {
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.cText3).opacity(hover ? 1 : 0)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(hover ? Color(ns: Theme.hover) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { Task { await app.connect(c) } }
        .onHover { hover = $0 }
        .contextMenu {
            Button("Edit…") { app.editingConnection = c }
            FolderMenu(c: c)
            Divider()
            Button("Delete", role: .destructive) { app.remove(c) }
        }
    }
}

struct ConnectionEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State var connection: SavedConnection
    @State private var uriText = ""
    @State private var password = ""
    @State private var testing = false
    @State private var testResult: (Bool, String)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(app.connections.contains { $0.id == connection.id } ? "Edit connection" : "New connection").font(.system(size: 16, weight: .semibold))
            Form {
                TextField("Name", text: $connection.name, prompt: Text("Production"))
                TextField(text: $uriText, prompt: Text("mongodb+srv://user@cluster.example.net/"), axis: .vertical) {
                    Text("Connection string").font(.system(size: 13))
                }
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: uriText) { _, v in
                        let (u, p) = ConnectionString.split(v)
                        if let p { password = p; uriText = u }
                    }
                SecureField("Password", text: $password, prompt: Text("Stored in your Keychain"))
                Picker("Color", selection: $connection.color) {
                    ForEach(Theme.connectionColors, id: \.1) { name, hex in
                        Label { Text(name) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(ns: Theme.hex(hex))) }.tag(hex)
                    }
                }
                Picker("Folder", selection: $connection.folderID) {
                    Text("None").tag(UUID?.none)
                    ForEach(app.folders) { f in
                        Label { Text(f.name) } icon: { Image(systemName: "folder.fill").foregroundStyle(Color(ns: Theme.hex(f.color))) }.tag(UUID?.some(f.id))
                    }
                }
                Toggle(isOn: $connection.isProduction) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Production")
                        Text("Red marking, and Touch ID or your password before deletes, drops, bulk updates, imports, index and validator changes.")
                            .font(.system(size: 11)).foregroundStyle(Color.cText3)
                    }
                }
                Toggle("Read-only (blocks writes, drops and $out from this app)", isOn: $connection.readOnly)
                Toggle("Favorite", isOn: $connection.favorite)
            }
            .formStyle(.grouped)
            if let r = testResult {
                Label(r.1, systemImage: r.0 ? "checkmark.circle.fill" : "xmark.octagon.fill").font(.system(size: 12))
                    .foregroundStyle(r.0 ? Color.cAccent : Color.cRed).textSelection(.enabled)
            }
            HStack {
                Button("Test") { Task { await test() } }.disabled(testing || uriText.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save & Connect") {
                    save()
                    let c = connection
                    dismiss()
                    Task { await app.connect(c) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(uriText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            let (u, p) = ConnectionString.split(connection.uri)
            uriText = u
            password = p ?? Keychain.get(connection.id) ?? ""
        }
    }

    private func save() {
        connection.uri = uriText.trimmingCharacters(in: .whitespacesAndNewlines)
        if connection.name.isEmpty { connection.name = connection.host.isEmpty ? "Untitled" : connection.host }
        app.upsert(connection, password: password)
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let svc = try await MongoService.connect(uri: ConnectionString.join(uriText, password: password))
            let dbs = (try? await svc.listDatabases().count) ?? 0
            testResult = (true, "Connected. MongoDB \(svc.serverVersion), \(dbs) databases.")
            await svc.disconnect()
        } catch {
            testResult = (false, error.localizedDescription)
        }
    }
}

/// Red "PRODUCTION" capsule used wherever a production connection is named.
struct ProdBadge: View {
    var small = false
    var body: some View {
        Text("PRODUCTION").font(.system(size: small ? 8.5 : 10, weight: .heavy)).tracking(0.5)
            .foregroundStyle(.white)
            .padding(.horizontal, small ? 5 : 7).padding(.vertical, small ? 1.5 : 2.5)
            .background(Color.cRed, in: Capsule())
    }
}
