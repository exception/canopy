import AppKit
import Foundation
import Network

/// Test/demo hook: when CANOPY_CONTROL_PORT is set, a line protocol on
/// 127.0.0.1 drives the UI and renders the window to PNG in-process (no
/// screen-recording permission, no system screenshot).
@MainActor
enum Automation {
    private static var listener: NWListener?
    private static var recorder: Timer?
    private static var frame = 0

    nonisolated static func startIfRequested() {
        guard let p = ProcessInfo.processInfo.environment["CANOPY_CONTROL_PORT"], let port = NWEndpoint.Port(p) else { return }
        Task { @MainActor in start(port) }
    }

    private static func start(_ port: NWEndpoint.Port) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { c in
            c.start(queue: .main)
            read(c, Data())
        }
        l.start(queue: .main)
        listener = l
    }

    nonisolated private static func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
            var b = buf
            if let data { b.append(data) }
            if let nl = b.firstIndex(of: 10) {
                let line = String(decoding: b[..<nl], as: UTF8.self)
                Task { @MainActor in
                    let reply = await handle(line)
                    c.send(content: Data((reply + "\n").utf8), completion: .contentProcessed { _ in c.cancel() })
                }
            } else if !done { read(c, b) } else { c.cancel() }
        }
    }

    static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.className.contains("Window") && $0.frame.width > 400 } }

    static func snapshot(_ path: String) -> Bool {
        guard let v = window?.contentView?.superview ?? window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    private static func handle(_ line: String) async -> String {
        let app = AppState.shared
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts.first ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "snapshot": return snapshot(arg) ? "ok" : "error"
        case "record":
            // record start <dir> [fps] | record stop
            let a = arg.split(separator: " ").map(String.init)
            if a.first == "start", a.count >= 2 {
                let dir = a[1]
                let fps = a.count > 2 ? Double(a[2]) ?? 12 : 12
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                frame = 0
                recorder?.invalidate()
                recorder = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { _ in
                    Task { @MainActor in
                        _ = snapshot(String(format: "%@/f%05d.png", dir, frame))
                        frame += 1
                    }
                }
                return "ok"
            }
            recorder?.invalidate(); recorder = nil
            return "ok \(frame) frames"
        case "size":
            let a = arg.split(separator: " ").compactMap { Double($0) }
            if a.count == 2, let w = window {
                w.setFrame(NSRect(x: 80, y: 80, width: a[0], height: a[1]), display: true)
            }
            return "ok"
        case "appearance":
            UserDefaults.standard.set(arg, forKey: "appearance")
            NSApp.appearance = arg == "light" ? NSAppearance(named: .aqua) : arg == "dark" ? NSAppearance(named: .darkAqua) : nil
            return "ok"
        case "connect":
            guard let c = app.connections.first(where: { $0.name == arg }) else { return "no such connection" }
            await app.connect(c)
            return app.session != nil ? "ok" : (app.connectError ?? "error")
        case "open":
            let a = arg.split(separator: " ").map(String.init)
            guard a.count >= 2, app.session != nil else { return "open <db> <coll> [mode]" }
            let t = app.open(db: a[0], collection: a[1])
            if a.count > 2, let mode = WorkspaceMode.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(a[2].lowercased()) }) { t.mode = mode }
            return "ok"
        case "server": app.openServer(); return "ok"
        case "mode":
            if let mode = WorkspaceMode.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(arg.lowercased()) }) { app.currentTab?.mode = mode }
            return "ok"
        case "view":
            if let v = DocViewMode.allCases.first(where: { $0.rawValue.lowercased() == arg.lowercased() }) { app.currentTab?.docs.view = v }
            return "ok"
        case "filter":
            app.currentTab?.docs.filterText = arg
            await app.currentTab?.docs.run()
            return "ok"
        case "sort":
            app.currentTab?.docs.sortText = arg
            app.currentTab?.docs.showOptions = true
            await app.currentTab?.docs.run()
            return "ok"
        case "select":
            app.currentTab?.docs.selected = Int(arg)
            return "ok"
        case "ask":
            guard let t = app.currentTab else { return "no tab" }
            t.docs.askText = arg
            await AIActions.ask(t.docs)
            return t.docs.askError ?? "ok"
        case "askpipe":
            guard let t = app.currentTab else { return "no tab" }
            t.mode = .aggregations
            t.agg.askText = arg
            await AIActions.pipeline(t.agg)
            return t.agg.askError ?? "ok"
        case "copilot":
            app.showCopilot = true
            app.copilot.send(arg)
            while app.copilot.busy { try? await Task.sleep(for: .milliseconds(200)) }
            return app.copilot.messages.last?.error ?? "ok"
        case "copilot-open": app.showCopilot = arg != "off"; return "ok"
        case "palette": app.showPalette = arg != "off"; return "ok"
        case "explain-ai":
            guard let t = app.currentTab else { return "no tab" }
            await AIActions.explain(t.explain)
            return "ok"
        case "schema-ai":
            guard let t = app.currentTab else { return "no tab" }
            await AIActions.schemaInsight(t.schema)
            return "ok"
        case "suggest-indexes":
            guard let t = app.currentTab else { return "no tab" }
            await AIActions.suggestIndexes(t.indexes)
            return "ok"
        case "live":
            app.currentTab?.docs.toggleLive()
            return "ok"
        case "expand":
            app.currentTab?.schema.expanded = arg
            return "ok"
        case "quit": NSApp.terminate(nil); return "ok"
        default: return "unknown command"
        }
    }
}
