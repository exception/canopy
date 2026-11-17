import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if app.session == nil {
                        ConnectView()
                    } else if app.tabs.isEmpty {
                        TabBar()
                        EmptyWorkspace()
                    } else {
                        TabBar()
                        if let tab = app.currentTab {
                            WorkspaceView(tab: tab).id(tab.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if app.showCopilot {
                    Rectangle().fill(Color.cHairline).frame(width: 1)
                    CopilotPanel()
                        .frame(width: 380)
                        .transition(.move(edge: .trailing))
                }
            }
            .background(Color(ns: Theme.window))
            .toolbar { MainToolbar() }
        }
        .overlay { if app.showPalette { CommandPalette().transition(.opacity) } }
        .overlay(alignment: .bottom) {
            if let t = app.toast {
                Text(t).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.cRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(ns: Theme.strongHairline)))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4).padding(.bottom, 24).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: app.showCopilot)
        .animation(.snappy(duration: 0.15), value: app.showPalette)
        .animation(.snappy, value: app.toast)
        .sheet(item: $app.editingConnection) { c in ConnectionEditor(connection: c) }
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppState.self) private var app

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let s = app.session {
                HStack(spacing: 7) {
                    Circle().fill(Color(ns: Theme.hex(s.saved.color))).frame(width: 8, height: 8)
                    Text(s.saved.name).font(.system(size: 12.5, weight: .semibold))
                    Text(s.saved.host).font(.system(size: 12)).foregroundStyle(Color.cText3)
                    if !s.service.serverVersion.isEmpty {
                        Text("v\(s.service.serverVersion)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.cText2)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Color.cPill, in: Capsule())
                    }
                    if s.readOnly {
                        Label("Read-only", systemImage: "lock.fill").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.cAmber)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { app.showPalette.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    Text("Go to collection…").foregroundStyle(Color.cText3)
                    Text("⌘K").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.cText3)
                }
                .font(.system(size: 12))
                .frame(width: 220, alignment: .leading)
            }
            .help("Command palette (⌘K)")
            Button { app.showCopilot.toggle() } label: {
                Label("Ask Claude", systemImage: "sparkles")
                    .foregroundStyle(app.showCopilot ? Color.cAI : Color.cText2)
            }
            .help("Ask Claude about your data (⌘J)")
        }
    }
}

struct EmptyWorkspace: View {
    @Environment(AppState.self) private var app
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "leaf").font(.system(size: 40, weight: .light)).foregroundStyle(Color.cAccent)
            Text("Pick a collection").font(.system(size: 17, weight: .semibold))
            Text("Choose one in the sidebar, press ⌘K to jump anywhere, or ask Claude about your data.")
                .font(.system(size: 13)).foregroundStyle(Color.cText2)
            HStack {
                Button("Go to collection…  ⌘K") { app.showPalette = true }
                Button("Ask Claude  ⌘J") { app.showCopilot = true }
                Button("Server overview") { app.openServer() }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TabBar: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(app.tabs) { t in TabChip(tab: t, selected: t.id == app.currentTabID) }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 36)
        .background(Color(ns: Theme.sidebar))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.cHairline).frame(height: 1) }
    }
}

struct TabChip: View {
    @Environment(AppState.self) private var app
    let tab: WorkspaceTab
    let selected: Bool
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.kind == .server ? "server.rack" : "square.stack.3d.up")
                .font(.system(size: 10.5)).foregroundStyle(selected ? Color.cAccent : Color.cText3)
            if tab.kind != .server {
                Text(tab.db).font(.system(size: 12)).foregroundStyle(Color.cText3)
                Text("›").font(.system(size: 11)).foregroundStyle(Color.cText3)
            }
            Text(tab.title).font(.system(size: 12, weight: selected ? .semibold : .regular)).foregroundStyle(selected ? Color.cText : Color.cText2)
            Button { app.close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.cText3)
                    .frame(width: 16, height: 16).background(hover ? Color.cPill : .clear, in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(hover || selected ? 1 : 0)
        }
        .padding(.leading, 10).padding(.trailing, 5)
        .frame(height: 28)
        .background(selected ? Color.cRaised : (hover ? Color(ns: Theme.hover) : .clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected ? Color.cHairline : .clear))
        .contentShape(Rectangle())
        .onTapGesture { app.currentTabID = tab.id }
        .onHover { hover = $0 }
    }
}
