import AppKit
import QuartzCore
import SwiftUI
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
        // Child panels (the completion popup) are their own windows too.
        if let w = window {
            for child in w.childWindows ?? [] where child.isVisible && child.attachedSheet == nil && child !== w.attachedSheet {
                guard let cv = child.contentView, let crep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { continue }
                cv.cacheDisplay(in: cv.bounds, to: crep)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let shadow = NSShadow(); shadow.shadowBlurRadius = 16; shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowOffset = NSSize(width: 0, height: -4)
                shadow.set()
                crep.draw(in: NSRect(x: child.frame.minX - w.frame.minX, y: child.frame.minY - w.frame.minY, width: child.frame.width, height: child.frame.height))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// The query bar's filter editor (the first code editor in the window).
    private static func filterTextView() -> CodeTextView? {
        func find(_ v: NSView) -> CodeTextView? {
            if let t = v as? CodeTextView { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        return window?.contentView.flatMap(find)
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
            if let v = DocViewMode.allCases.first(where: { $0.rawValue.lowercased() == arg.lowercased() }) { withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { app.currentTab?.docs.view = v } }
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
        case "presets-snapshot":
            guard let m = app.currentTab?.docs else { return "error" }
            let v = NSHostingView(rootView: PresetsPanel(m: m, maxHeight: 2000))
            v.appearance = NSApp.effectiveAppearance
            v.frame.size = v.fittingSize
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return "error" }
            v.cacheDisplay(in: v.bounds, to: rep)
            return (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: arg))) != nil ? "ok" : "error"
        case "type":
            // type <text>: types into the filter editor like the keyboard would, so autocomplete runs.
            guard let tv = filterTextView() else { return "no editor" }
            if tv.window?.firstResponder !== tv {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
            for ch in arg { tv.insertText(String(ch), replacementRange: tv.selectedRange()); try? await Task.sleep(for: .milliseconds(20)) }
            return "ok"
        case "key":
            // key return|tab|escape|down|up: a key press in the filter editor.
            guard let tv = filterTextView() else { return "no editor" }
            let sel: Selector = ["return": #selector(NSResponder.insertNewline(_:)), "tab": #selector(NSResponder.insertTab(_:)),
                                 "escape": #selector(NSResponder.cancelOperation(_:)), "down": #selector(NSResponder.moveDown(_:)),
                                 "up": #selector(NSResponder.moveUp(_:))][arg] ?? #selector(NSResponder.insertNewline(_:))
            tv.doCommand(by: sel)
            return "ok \(tv.string) caret=\(tv.selectedRange().location)"
        case "click-ref":
            // click-ref <field>: follows the reference link on the selected document's field.
            guard let m = app.currentTab?.docs, let i = m.selected ?? (m.docs.isEmpty ? nil : 0), let v = m.docs[i][arg],
                  let refs = app.referenceLinker(db: m.db), let target = refs.target(forKey: arg), let f = ReferenceLinker.filter(for: v) else { return "no reference" }
            app.openReference(db: m.db, collection: target, filter: f)
            return "ok \(target) \(f)"
        case "menu-keys":
            // menu-keys <key>: menu items bound to ⌘<key>, to catch shortcut clashes.
            func walk(_ m: NSMenu, _ path: String) -> [String] {
                m.items.flatMap { i -> [String] in
                    var out: [String] = []
                    if i.keyEquivalent == arg, i.keyEquivalentModifierMask == .command { out.append(path + i.title + (i.isEnabled ? "" : " (disabled)")) }
                    if let sub = i.submenu { out += walk(sub, path + i.title + " › ") }
                    return out
                }
            }
            return (NSApp.mainMenu.map { walk($0, "") } ?? []).joined(separator: "; ")
        case "press":
            // press <key>: sends ⌘<key> through the main menu like the keyboard would.
            guard let w = window, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: w.windowNumber,
                                                            context: nil, characters: arg, charactersIgnoringModifiers: arg, isARepeat: false, keyCode: 13) else { return "error" }
            let handled = NSApp.mainMenu?.performKeyEquivalent(with: e) ?? false
            try? await Task.sleep(for: .milliseconds(300))
            return "handled=\(handled) tabs=\(app.tabs.count) windowVisible=\(w.isVisible)"
        case "select":
            app.currentTab?.docs.selected = Int(arg)
            return "ok"
        case "scroll-bench":
            // scroll-bench <x>: scrolls the scroll view under window point (x, 300) to the bottom in
            // 20 pt steps, forcing a redraw per step; reports per-frame milliseconds.
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
                  let fv = w.contentView?.superview else { return "no window" }
            let x = Double(arg) ?? 150
            var v = fv.hitTest(fv.convert(NSPoint(x: x, y: w.frame.height - 300), from: nil))
            while let view = v, !(view is NSScrollView) { v = view.superview }
            guard let sv = v as? NSScrollView, let doc = sv.documentView else { return "no scroll view" }
            var times: [Double] = []
            sv.contentView.scroll(to: .zero); sv.reflectScrolledClipView(sv.contentView); w.displayIfNeeded()
            for _ in 0..<400 {
                let maxY = doc.frame.height - sv.contentView.bounds.height
                let y = sv.contentView.bounds.origin.y
                if y >= maxY - 1 { break }
                let t0 = CACurrentMediaTime()
                sv.contentView.scroll(to: NSPoint(x: 0, y: min(maxY, y + 20)))
                sv.reflectScrolledClipView(sv.contentView)
                w.displayIfNeeded()
                CATransaction.flush()
                RunLoop.current.run(until: Date())
                times.append((CACurrentMediaTime() - t0) * 1000)
            }
            guard !times.isEmpty else { return "nothing to scroll" }
            let sorted = times.sorted()
            return String(format: "frames %d  median %.2f ms  p95 %.2f ms  max %.2f ms  >16ms: %d",
                          times.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last!, times.filter { $0 > 16 }.count)
        case "reload-db":
            guard let s = app.session else { return "no session" }
            let t0 = Date()
            await s.loadCollections(arg)
            return String(format: "%.2f s, %d stats", Date().timeIntervalSince(t0), s.stats.keys.filter { $0.hasPrefix(arg + ".") }.count)
        case "stats-bench":
            // Simulates stats trickling in from a slow server: 60 single-collection stat updates,
            // each followed by a forced render. Reports main-thread ms per update.
            guard let s = app.session, let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return "no session" }
            let keys = s.stats.keys.filter { $0.hasPrefix("bigdb.") }.sorted()
            guard !keys.isEmpty else { return "no bigdb stats" }
            var times: [Double] = []
            for i in 0..<60 {
                let k = keys[i % keys.count]
                let t0 = CACurrentMediaTime()
                if var st = s.stats[k] { st.count = (st.count ?? 0) + 1; s.stats[k] = st }
                RunLoop.current.run(until: Date())
                w.contentView?.layoutSubtreeIfNeeded()
                w.displayIfNeeded()
                CATransaction.flush()
                times.append((CACurrentMediaTime() - t0) * 1000)
            }
            let sorted = times.sorted()
            return String(format: "updates %d  median %.2f ms  p95 %.2f ms  max %.2f ms", times.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last!)
        case "hittest":
            let a = arg.split(separator: " ").compactMap { Double($0) }
            guard a.count == 2, let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return "hittest x y" }
            return TitlebarDoubleClick.describe(a[0], a[1], in: w)
        case "zoom":
            guard let w = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return "no window" }
            TitlebarDoubleClick.perform(on: w)
            return "\(Int(w.frame.width))x\(Int(w.frame.height))"
        case "toggle-folder":
            guard let f = app.folders.first(where: { $0.name == arg }) else { return "no such folder" }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { app.toggleFolder(f.id) }
            return "ok"
        case "new-folder":
            let f = app.newFolder(arg.isEmpty ? "New Folder" : arg)
            return f.id.uuidString
        case "move":
            // move <connection name> -> <folder name | none>
            let parts = arg.components(separatedBy: " -> ")
            guard parts.count == 2, let c = app.connections.first(where: { $0.name == parts[0] }) else { return "move <conn> -> <folder>" }
            app.move(c.id, to: app.folders.first { $0.name == parts[1] }?.id)
            return "ok"
        case "delete":
            guard let t = app.currentTab, let i = Int(arg) else { return "delete <row>" }
            let before = t.docs.docs.count
            await t.docs.delete(i)
            return t.docs.docs.count < before ? "deleted" : "kept"
        case "edit-connection":
            app.editingConnection = app.connections.first { $0.name == arg }
            return app.editingConnection == nil ? "no such connection" : "ok"
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
