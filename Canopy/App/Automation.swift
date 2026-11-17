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
    private static var frameTimes: [Date] = []
    private static var recordDir = ""

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

    static func snapshot(_ path: String, scale: CGFloat? = nil) -> Bool {
        guard let v = window?.contentView?.superview ?? window?.contentView else { return false }
        let rep: NSBitmapImageRep
        if let scale {
            guard let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale), pixelsHigh: Int(v.bounds.height * scale),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
            r.size = v.bounds.size
            rep = r
        } else {
            guard let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
            rep = r
        }
        v.cacheDisplay(in: v.bounds, to: rep)
        // Composite an attached sheet (its own window) where it sits on screen.
        if let w = window, let sheet = w.attachedSheet, let sv = sheet.contentView?.superview ?? sheet.contentView,
           let srep = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
            sv.cacheDisplay(in: sv.bounds, to: srep)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            let x = sheet.frame.minX - w.frame.minX, y = sheet.frame.minY - w.frame.minY
            let shadow = NSShadow(); shadow.shadowBlurRadius = 30; shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.shadowOffset = NSSize(width: 0, height: -8)
            shadow.set()
            let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: sheet.frame.width, height: sheet.frame.height), xRadius: 14, yRadius: 14)
            NSColor.windowBackgroundColor.setFill(); path.fill()
            NSShadow().set()
            path.addClip()
            srep.draw(in: NSRect(x: x, y: y, width: sheet.frame.width, height: sheet.frame.height))
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// Types text into a field a few characters at a time (for recordings).
    private static func typeOut(_ text: String, _ set: (String) -> Void) async {
        guard ProcessInfo.processInfo.environment["CANOPY_TYPE_DELAY"] != "0" else { set(text); return }
        var s = ""
        for ch in text {
            s.append(ch)
            set(s)
            try? await Task.sleep(for: .milliseconds(28))
        }
        try? await Task.sleep(for: .milliseconds(250))
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
                frameTimes = []
                recordDir = dir
                recorder?.invalidate()
                recorder = Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { _ in
                    Task { @MainActor in
                        if snapshot(String(format: "%@/f%05d.png", dir, frame), scale: 1) {
                            frameTimes.append(Date())
                            frame += 1
                        }
                    }
                }
                RunLoop.main.add(recorder!, forMode: .common)
                return "ok"
            }
            recorder?.invalidate(); recorder = nil
            // ffmpeg concat list with real frame durations.
            var list = ""
            for i in 0..<frameTimes.count {
                let d = i + 1 < frameTimes.count ? frameTimes[i + 1].timeIntervalSince(frameTimes[i]) : 0.1
                list += String(format: "file 'f%05d.png'\nduration %.3f\n", i, d)
            }
            if frameTimes.count > 0 { list += String(format: "file 'f%05d.png'\n", frameTimes.count - 1) }
            try? list.write(toFile: recordDir + "/frames.txt", atomically: true, encoding: .utf8)
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
        case "apply-proposal":
            for m in app.copilot.messages.reversed() {
                for p in m.parts.reversed() { if case .proposal(let pr) = p { app.copilot.apply(pr); return "ok" } }
            }
            return "none"
        case "sleep":
            try? await Task.sleep(for: .milliseconds(Int(arg) ?? 500))
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
            await typeOut(arg) { t.docs.askText = $0 }
            await AIActions.ask(t.docs)
            return t.docs.askError ?? "ok"
        case "askpipe":
            guard let t = app.currentTab else { return "no tab" }
            t.mode = .aggregations
            await typeOut(arg) { t.agg.askText = $0 }
            await AIActions.pipeline(t.agg)
            return t.agg.askError ?? "ok"
        case "copilot":
            app.showCopilot = true
            await typeOut(arg) { app.copilot.input = $0 }
            app.copilot.send()
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
        case "validator-ai":
            guard let t = app.currentTab else { return "no tab" }
            await AIActions.validator(t.schema)
            return t.schema.validatorError ?? "ok"
        case "suggest-indexes":
            guard let t = app.currentTab else { return "no tab" }
            await AIActions.suggestIndexes(t.indexes)
            return "ok"
        case "bulk-ai":
            guard let t = app.currentTab else { return "no tab" }
            let b = BulkModel(session: t.docs.session, db: t.db, collection: t.collection, kind: .update, filter: t.docs.filterText)
            t.docs.bulk = b
            try? await Task.sleep(for: .milliseconds(600))
            await typeOut(arg) { b.askText = $0 }
            await AIActions.update(b)
            return b.askError ?? "ok"
        case "new-connection":
            app.editingConnection = SavedConnection(name: "", uri: arg.isEmpty ? "mongodb://localhost:27017" : arg)
            return "ok"
        case "close-sheet":
            app.currentTab?.docs.bulk = nil
            app.editingConnection = nil
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
