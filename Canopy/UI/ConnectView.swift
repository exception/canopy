import SwiftUI

/// Sidebar list of saved connections (when disconnected).
struct ConnectionList: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("CONNECTIONS").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Color.cText3)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(app.connections.sorted { ($0.favorite ? 0 : 1, -($0.lastUsed?.timeIntervalSince1970 ?? 0)) < ($1.favorite ? 0 : 1, -($1.lastUsed?.timeIntervalSince1970 ?? 0)) }) { c in
                        ConnectionRow(c: c)
                    }
                }
                .padding(.horizontal, 6)
            }
            Spacer()
            Button { app.editingConnection = SavedConnection(name: "", uri: "mongodb://localhost:27017") } label: {
                Label("New connection", systemImage: "plus").font(.system(size: 12.5))
            }
            .buttonStyle(.borderless)
            .padding(12)
        }
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
                    Text(c.name).font(.system(size: 12.5, weight: .medium))
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
        .contextMenu {
            Button("Connect") { Task { await app.connect(c) } }
            Button("Edit…") { app.editingConnection = c }
            Button(c.favorite ? "Unfavorite" : "Favorite") { var x = c; x.favorite.toggle(); app.upsert(x, password: nil) }
            Button("Duplicate") { var x = c; x.id = UUID(); x.name += " copy"; app.upsert(x, password: Keychain.get(c.id)) }
            Divider()
            Button("Delete", role: .destructive) { app.remove(c) }
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
                VStack(spacing: 0) {
                    ForEach(Array(app.connections.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider().padding(.leading, 44) }
                        BigConnectionRow(c: c)
                    }
                }
                .card(12)
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
