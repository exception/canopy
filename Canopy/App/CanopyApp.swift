import AppKit
import SwiftUI

@main
struct CanopyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app = AppState.shared
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        Window("Canopy", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 980, minHeight: 600)
                .onAppear { applyAppearance() }
                .onChange(of: appearance) { applyAppearance() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection…") { app.editingConnection = SavedConnection(name: "", uri: "mongodb://localhost:27017") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandMenu("Connection") {
                ForEach(Array(app.connections.prefix(9).enumerated()), id: \.element.id) { i, c in
                    Button(c.name + (c.isProduction ? " (production)" : "")) { Task { await app.connect(c) } }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                        .disabled(app.session?.saved.id == c.id)
                }
                Divider()
                Button("Disconnect") { Task { await app.disconnect() } }.disabled(app.session == nil)
            }
            CommandMenu("Go") {
                Button("Command Palette…") { app.showPalette.toggle() }.keyboardShortcut("k")
                Button("Ask Claude") { app.showCopilot.toggle() }.keyboardShortcut("j")
                Divider()
                Button("Next Tab") { app.selectTab(offset: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { app.selectTab(offset: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Close Tab") { if let id = app.currentTabID { app.close(id) } }.keyboardShortcut("w")
                Divider()
                ForEach(Array(WorkspaceMode.allCases.enumerated()), id: \.offset) { i, m in
                    Button(m.rawValue) { app.currentTab?.mode = m }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Button("Server Overview") { app.openServer() }.keyboardShortcut("0")
            }
            CommandMenu("Query") {
                Button("Run") { Task { await app.currentTab?.docs.run() } }.keyboardShortcut(.return)
                Button("Refresh") { Task { await app.currentTab?.docs.run(resetPage: false) } }.keyboardShortcut("r")
                Button("Ask AI to Write Query") { NotificationCenter.default.post(name: .focusAsk, object: nil) }.keyboardShortcut("l")
                Button("Explain Current Query") {
                    guard let t = app.currentTab, let q = try? t.docs.buildQuery() else { return }
                    t.mode = .explain
                    Task { await t.explain.run(query: q, label: t.docs.filterText.isEmpty ? "{}" : t.docs.filterText) }
                }.keyboardShortcut("e")
                Button("Insert Document") { app.currentTab?.docs.beginInsert() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView().environment(app)
        }
    }

    private func applyAppearance() {
        NSApp.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "light" ? NSAppearance(named: .aqua) : nil
    }
}

extension Notification.Name {
    static let focusAsk = Notification.Name("canopy.focusAsk")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        Automation.startIfRequested()
        Task { @MainActor in TitlebarDoubleClick.install() }
        Task { @MainActor in ToolServer.shared.start() }
        if let auto = ProcessInfo.processInfo.environment["CANOPY_AUTOCONNECT"] {
            Task { @MainActor in
                let app = AppState.shared
                if let c = app.connections.first(where: { $0.name == auto }) { await app.connect(c) }
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        MainActor.assumeIsolated { AppState.shared.saveWorkspace() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
