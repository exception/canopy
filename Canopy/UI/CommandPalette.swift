import SwiftUI

struct PaletteItem: Identifiable {
    var id: String
    var icon: String
    var title: String
    var subtitle: String
    var score = 0
    var action: () -> Void
}

struct CommandPalette: View {
    @Environment(AppState.self) private var app
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { app.showPalette = false }
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Color.cText3)
                    TextField("Jump to a collection, or type a command…", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 16))
                        .focused($focused)
                        .onSubmit { run(index) }
                        .onKeyPress(.downArrow) { index = min(index + 1, max(items.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                        .onKeyPress(.escape) { app.showPalette = false; return .handled }
                }
                .padding(.horizontal, 16).frame(height: 52)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, it in
                                HStack(spacing: 10) {
                                    Image(systemName: it.icon).font(.system(size: 12)).foregroundStyle(i == index ? Color.cAccent : Color.cText3).frame(width: 18)
                                    Text(it.title).font(.system(size: 13, weight: .medium))
                                    Text(it.subtitle).font(.system(size: 12)).foregroundStyle(Color.cText3)
                                    Spacer()
                                    if i == index { Text("↩").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cText3) }
                                }
                                .padding(.horizontal, 12).frame(height: 34)
                                .background(i == index ? Color(ns: Theme.selection) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .contentShape(Rectangle())
                                .onTapGesture { run(i) }
                                .id(i)
                            }
                            if items.isEmpty {
                                Text("No matches").font(.system(size: 12.5)).foregroundStyle(Color.cText3).padding(20)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: index) { proxy.scrollTo(index) }
                }
            }
            .frame(width: 620)
            .canopyGlass(cornerRadius: 14)
            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { index = 0 }
    }

    private var items: [PaletteItem] {
        var out: [PaletteItem] = []
        if let s = app.session {
            for (db, coll) in s.allNamespaces {
                let st = s.stat(db, coll)
                out.append(PaletteItem(id: "c:\(db).\(coll)", icon: "square.stack.3d.up", title: coll,
                                       subtitle: "\(db)\(st?.count.map { " · \(Fmt.compact($0)) docs" } ?? "")") { app.open(db: db, collection: coll) })
            }
            if let t = app.currentTab, t.kind != .server {
                for m in WorkspaceMode.allCases {
                    out.append(PaletteItem(id: "m:\(m.rawValue)", icon: m.icon, title: m.rawValue, subtitle: "in \(t.collection)") { t.mode = m })
                }
            }
            out.append(PaletteItem(id: "a:server", icon: "server.rack", title: "Server overview", subtitle: "live ops, databases") { app.openServer() })
            out.append(PaletteItem(id: "a:claude", icon: "sparkles", title: "Ask Claude", subtitle: "about this connection") { app.showCopilot = true })
            out.append(PaletteItem(id: "a:disconnect", icon: "eject", title: "Disconnect", subtitle: s.saved.name) { Task { await app.disconnect() } })
        }
        for c in app.connections where c.id != app.session?.saved.id {
            out.append(PaletteItem(id: "k:\(c.id)", icon: "bolt.horizontal.circle", title: "Connect to \(c.name)", subtitle: c.host) { Task { await app.connect(c) } })
        }
        out.append(PaletteItem(id: "a:new", icon: "plus", title: "New connection", subtitle: "") { app.editingConnection = SavedConnection(name: "", uri: "mongodb://localhost:27017") })
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(out.prefix(60)) }
        return out.compactMap { it -> PaletteItem? in
            var it = it
            guard let sc = Fuzzy.score(q, it.title.lowercased() + " " + it.subtitle.lowercased()) else { return nil }
            it.score = sc + (it.title.lowercased().hasPrefix(q) ? 100 : 0)
            return it
        }
        .sorted { $0.score > $1.score }
        .prefix(60).map { $0 }
    }

    private func run(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let it = items[i]
        app.showPalette = false
        query = ""
        it.action()
    }
}

enum Fuzzy {
    /// Subsequence match; consecutive and word-start hits score higher.
    static func score(_ q: String, _ s: String) -> Int? {
        var score = 0, si = s.startIndex, last: String.Index? = nil
        for qc in q {
            guard let found = s[si...].firstIndex(of: qc) else { return nil }
            if let last, s.index(after: last) == found { score += 5 }
            if found == s.startIndex || " ._-".contains(s[s.index(before: found)]) { score += 8 }
            score += 1
            last = found
            si = s.index(after: found)
        }
        return score - s.count / 10
    }
}
