import SwiftUI

struct DocumentsView: View {
    @Environment(AppState.self) private var app
    @Bindable var m: DocumentsModel
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            QueryBar(m: m)
            Rectangle().fill(Color.cHairline).frame(height: 1)
            ResultsToolbar(m: m)
            HStack(spacing: 0) {
                results
                if m.live || !m.events.isEmpty {
                    Rectangle().fill(Color.cHairline).frame(width: 1)
                    LivePanel(m: m).frame(width: 330)
                } else if m.editing != nil || (app.showInspector && m.selected != nil && m.view != .list) {
                    Rectangle().fill(Color.cHairline).frame(width: 1)
                    DocumentInspector(m: m).frame(width: 400)
                }
            }
            .overlay {
                if dropping {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.cAccent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .background(Color.cAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(Label("Drop JSON, NDJSON or CSV to import into \(m.collection)", systemImage: "square.and.arrow.down").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.cAccent))
                        .padding(10)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                guard let p = providers.first else { return false }
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await m.importFile(url, app: app) }
                }
                return true
            }
        }
    }

    @ViewBuilder private var results: some View {
        if let e = m.error {
            ErrorState(message: e)
        } else if m.docs.isEmpty && m.loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if m.docs.isEmpty && m.hasRun {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 28, weight: .light)).foregroundStyle(Color.cText3)
                Text("No documents match").font(.system(size: 14, weight: .medium))
                Text(m.filterText.isEmpty ? "This collection is empty." : "Try loosening the filter, or ask Claude.").font(.system(size: 12)).foregroundStyle(Color.cText3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch m.view {
            case .list: DocumentList(m: m)
            case .table: DocumentTable(m: m)
            case .json: CodeView(text: BFormat.text(.array(m.docs.map { .document($0) })))
            }
        }
    }
}

struct ErrorState: View {
    var message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 26, weight: .light)).foregroundStyle(Color.cRed)
            Text(message).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(Color.cText2).multilineTextAlignment(.center)
                .textSelection(.enabled).frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Query bar

struct QueryBar: View {
    @Bindable var m: DocumentsModel
    @State private var showHistory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AskBar(text: $m.askText, placeholder: "Ask for data in plain words — e.g. \u{201C}refunded orders over 100k from Rosario this month\u{201D}",
                   busy: m.askBusy, note: m.askNote, error: m.askError) { Task { await AIActions.ask(m) } }
            HStack(alignment: .top, spacing: 8) {
                QueryField(label: "Filter", text: $m.filterText, placeholder: "{ field: \"value\" }", error: m.filterError,
                           completer: { m.catalog.isEmpty ? nil : QueryCompletion.complete($0, cursor: $1, catalog: m.catalog, operators: true) }) { Task { await m.run() } }
                PresetsButton(m: m)
                Button { withAnimation(.snappy(duration: 0.18)) { m.showOptions.toggle() } } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                        .foregroundStyle(m.showOptions || !m.sortText.isEmpty || !m.projectText.isEmpty ? Color.cAccent : Color.cText2)
                        .frame(width: 30, height: 30).background(Color.cPill.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain).help("Project, sort, limit")
                Button { showHistory.toggle() } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 12)).foregroundStyle(Color.cText2)
                        .frame(width: 30, height: 30).background(Color.cPill.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain).help("History & favorites")
                .popover(isPresented: $showHistory, arrowEdge: .bottom) { HistoryPopover(m: m, dismiss: { showHistory = false }) }
                PillButton(title: "Reset", tint: .cText2) { Task { await m.reset() } }
                    .frame(height: 30)
                Button { Task { await m.run() } } label: {
                    HStack(spacing: 5) {
                        if m.loading { ProgressView().controlSize(.mini).tint(.white) } else { Image(systemName: "play.fill").font(.system(size: 10)) }
                        Text("Find").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 30)
                    .background(Color.cAccent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
            }
            if m.showOptions {
                HStack(alignment: .top, spacing: 8) {
                    QueryField(label: "Project", text: $m.projectText, placeholder: "{ name: 1, email: 1 }", error: nil,
                               completer: { m.catalog.isEmpty ? nil : QueryCompletion.complete($0, cursor: $1, catalog: m.catalog, operators: false) }) { Task { await m.run() } }
                    QueryField(label: "Sort", text: $m.sortText, placeholder: "{ createdAt: -1 }", error: nil,
                               completer: { m.catalog.isEmpty ? nil : QueryCompletion.complete($0, cursor: $1, catalog: m.catalog, operators: false) }) { Task { await m.run() } }
                    HStack(spacing: 6) {
                        Text("Limit").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cText3)
                        Picker("", selection: $m.limit) { ForEach([20, 50, 100, 250, 500, 1000], id: \.self) { Text("\($0)").tag($0) } }
                            .labelsHidden().frame(width: 76)
                            .onChange(of: m.limit) { Task { await m.run() } }
                    }
                    .frame(height: 30)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.cPanel)
    }
}

struct QueryField: View {
    var label: String
    @Binding var text: String
    var placeholder: String
    var error: String?
    var completer: ((String, Int) -> CompletionResult?)? = nil
    var onSubmit: () -> Void
    @State private var height: CGFloat = CodeEditor.singleLineHeight

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Centered on the first line, so it stays put when the field grows.
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(error != nil ? Color.cRed : Color.cText3)
                .frame(width: 52, height: CodeEditor.singleLineHeight, alignment: .leading).padding(.leading, 10)
            CodeEditor(text: $text, placeholder: placeholder, singleLine: true, onSubmit: onSubmit, onHeight: { h in
                let c = min(max(h, CodeEditor.singleLineHeight), 160)
                if abs(c - height) > 0.5 { height = c }
            }, completer: completer)
                .frame(height: height)
        }
        .background(Color.cField, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(error != nil ? Color.cRed.opacity(0.6) : Color.cHairline))
        .help(error ?? "")
    }
}

struct HistoryPopover: View {
    @Bindable var m: DocumentsModel
    var dismiss: () -> Void

    var body: some View {
        let entries = History.shared.entries(for: "\(m.db).\(m.collection)").filter { $0.kind == "find" }
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent queries").font(.system(size: 12, weight: .semibold)).padding(12)
            Divider()
            if entries.isEmpty {
                Text("Queries you run show up here.").font(.system(size: 12)).foregroundStyle(Color.cText3).padding(16)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries.sorted { ($0.favorite ? 0 : 1) < ($1.favorite ? 0 : 1) }) { e in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(e.filter.isEmpty ? "{}" : e.filter).font(.system(size: 11.5, design: .monospaced)).lineLimit(2)
                                if !e.sort.isEmpty { Text("sort \(e.sort)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.cText3) }
                                Text(e.at, format: .relative(presentation: .named)).font(.system(size: 10.5)).foregroundStyle(Color.cText3)
                            }
                            Spacer()
                            Button { History.shared.toggleFavorite(e.id) } label: {
                                Image(systemName: e.favorite ? "star.fill" : "star").foregroundStyle(e.favorite ? Color.cAmber : Color.cText3)
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            m.apply(filter: e.filter, sort: e.sort, project: e.project)
                            dismiss()
                            Task { await m.run() }
                        }
                        Divider()
                    }
                }
            }
        }
        .frame(width: 380, height: 360)
    }
}

// MARK: - Results toolbar

struct ResultsToolbar: View {
    @Environment(AppState.self) private var app
    @Bindable var m: DocumentsModel

    var body: some View {
        HStack(spacing: 10) {
            ViewModeSwitch(selection: $m.view)
            if !m.session.readOnly {
                PillButton(title: "Insert", icon: "plus") { m.beginInsert() }
                Menu {
                    Button("Update matching documents…") { m.bulk = BulkModel(session: m.session, db: m.db, collection: m.collection, kind: .update, filter: m.filterText) }
                    Button("Delete matching documents…") { m.bulk = BulkModel(session: m.session, db: m.db, collection: m.collection, kind: .delete, filter: m.filterText) }
                } label: { Label("Bulk", systemImage: "square.stack.3d.forward.dottedline").font(.system(size: 12)) }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            Menu {
                Button("Copy page as JSON (Extended JSON)") { app.copy(BFormat.text(.array(m.docs.map { .document($0) }), style: .ejson), label: "Copied \(m.docs.count) documents") }
                Button("Copy page as mongosh") { app.copy(BFormat.text(.array(m.docs.map { .document($0) })), label: "Copied \(m.docs.count) documents") }
                Button("Export page as CSV…") { Export.csv(m.docs, columns: m.columns, name: m.collection) }
                Button("Export page as JSON…") { Export.json(m.docs, name: m.collection) }
            } label: { Label("Export", systemImage: "square.and.arrow.up").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).fixedSize()
            Button {
                guard let q = try? m.buildQuery(), let tab = app.currentTab else { return }
                tab.mode = .explain
                Task { await tab.explain.run(query: q, label: m.filterText.isEmpty ? "{}" : m.filterText) }
            } label: { Label("Explain", systemImage: "gauge.with.dots.needle.33percent").font(.system(size: 12)) }
                .buttonStyle(.borderless)
            Button { m.toggleLive() } label: {
                HStack(spacing: 5) {
                    Circle().fill(m.live ? Color.cRed : Color.cText3).frame(width: 7, height: 7)
                        .shadow(color: m.live ? Color.cRed : .clear, radius: 4)
                        .symbolEffect(.pulse, isActive: m.live)
                    Text(m.live ? "Live" : "Watch").font(.system(size: 12, weight: m.live ? .semibold : .regular))
                }
                .foregroundStyle(m.live ? Color.cRed : Color.cText2)
            }
            .buttonStyle(.borderless)
            .help(m.session.service.isReplicaSet ? "Tail changes to this collection as they happen" : "Change streams need a replica set")
            if m.newSinceRun > 0 {
                Button { Task { await m.run(resetPage: false) } } label: {
                    Label("\(m.newSinceRun) change\(m.newSinceRun == 1 ? "" : "s") · refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 22).background(Color.cAccent, in: Capsule())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
            Spacer()
            if m.loading { ProgressView().controlSize(.small) }
            if m.hasRun && m.error == nil {
                Text("\(Fmt.ms(m.elapsed))").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.cText3)
            }
            Text(m.rangeLabel).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Color.cText2)
            HStack(spacing: 2) {
                Button { Task { await m.prev() } } label: { Image(systemName: "chevron.left") }.disabled(m.page == 0)
                Button { Task { await m.next() } } label: { Image(systemName: "chevron.right") }.disabled(!m.canNext)
            }
            .buttonStyle(.borderless)
            Button { Task { await m.run(resetPage: false) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh (⌘R)")
        }
        .padding(.horizontal, 16).frame(height: 40)
        .background(Color(ns: Theme.window))
        .sheet(item: $m.bulk) { b in BulkSheet(m: b) { Task { await m.run(resetPage: false) } } }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.cHairline).frame(height: 1) }
    }
}

// MARK: - List view

struct DocumentList: View {
    @Environment(AppState.self) private var app
    @Bindable var m: DocumentsModel
    @FocusState private var focused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(m.docs.enumerated()), id: \.offset) { i, d in
                        Group {
                            if m.editing == i {
                                InlineEditor(m: m)
                            } else {
                                DocumentCard(m: m, index: i, doc: d)
                            }
                        }
                        .id(i)
                    }
                }
                .padding(14)
            }
            .focusable(m.editing == nil)
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.downArrow) { move(1, proxy); return .handled }
            .onKeyPress(.upArrow) { move(-1, proxy); return .handled }
            .onKeyPress(.return) {
                if let i = m.selected, !m.session.readOnly { m.beginEdit(i); return .handled }
                return .ignored
            }
            .onKeyPress(characters: ["c"], phases: .down) { press in
                guard press.modifiers.contains(.command), let i = m.selected, m.docs.indices.contains(i) else { return .ignored }
                app.copy(BFormat.text(m.docs[i], style: .ejson), label: "Copied document")
                return .handled
            }
        }
        .background(Color(ns: Theme.window))
    }

    private func move(_ d: Int, _ proxy: ScrollViewProxy) {
        guard !m.docs.isEmpty else { return }
        let next = max(0, min(m.docs.count - 1, (m.selected ?? -1) + d))
        m.selected = next
        withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(next, anchor: .center) }
    }
}

struct DocumentCard: View {
    @Environment(AppState.self) private var app
    @Bindable var m: DocumentsModel
    let index: Int
    let doc: BDoc
    @State private var hover = false
    @State private var expandAll = false

    var body: some View {
        let selected = m.selected == index
        VStack(alignment: .leading, spacing: 0) {
            DocTree(doc: doc, expandAll: expandAll, maxTopLevel: 14, onFilter: { p, v in Task { await m.addFilter(path: p, value: v) } }, refs: app.referenceLinker(db: m.db))
                .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.cAccent.opacity(0.6) : Color.cHairline, lineWidth: selected ? 1.5 : 1))
        .overlay(alignment: .topTrailing) {
            if hover {
                HStack(spacing: 2) {
                    iconButton(expandAll ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", expandAll ? "Collapse" : "Expand all") { expandAll.toggle() }
                    iconButton("sparkles", "Ask Claude about this document", tint: .cAI) {
                        m.selected = index
                        app.showCopilot = true
                        app.copilot.send("Explain this document: what it represents, anything unusual about its values compared with the rest of the collection, and related documents worth looking at.")
                    }
                    iconButton("doc.on.doc", "Copy as JSON") { app.copy(BFormat.text(doc, style: .ejson), label: "Copied document") }
                    if !m.session.readOnly {
                        iconButton("pencil", "Edit") { m.beginEdit(index) }
                        iconButton("plus.square.on.square", "Clone") { m.beginInsert(template: doc) }
                        iconButton("trash", "Delete", tint: .cRed) { confirmDelete() }
                    }
                }
                .padding(4)
                .background(Color.cRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.cHairline))
                .padding(6)
            }
        }
        .contentShape(Rectangle())
        // One tap handler that reads the click count. Pairing onTapGesture with
        // onTapGesture(count: 2) makes SwiftUI hold every single click for the double-click
        // interval (~0.3 s), which delayed every chevron inside the card.
        .simultaneousGesture(TapGesture().onEnded {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2, !m.session.readOnly { m.beginEdit(index) } else { m.selected = index }
        })
        .onHover { hover = $0 }
    }

    private func iconButton(_ icon: String, _ help: String, tint: Color = .cText2, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11.5)).foregroundStyle(tint).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func confirmDelete() {
        let a = NSAlert()
        a.messageText = "Delete this document?"
        a.informativeText = "_id: \(doc.id.map { BFormat.preview($0) } ?? "?")"
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { Task { await m.delete(index) } }
    }
}

struct InlineEditor: View {
    @Bindable var m: DocumentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(m.editing == -1 ? "New document" : "Editing").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("⌘↩ to save · esc to cancel").font(.system(size: 11)).foregroundStyle(Color.cText3)
            }
            CodeEditor(text: $m.editText, focusOnAppear: true, onSubmit: { Task { await m.saveEdit() } })
                .frame(minHeight: 160, idealHeight: CGFloat(min(m.editText.split(separator: "\n").count, 30)) * 16 + 20)
                .background(Color.cField, in: RoundedRectangle(cornerRadius: 7))
            if let e = m.editError { Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(Color.cRed) }
            HStack {
                Spacer()
                Button("Cancel") { m.editing = nil }.keyboardShortcut(.cancelAction)
                Button(m.editing == -1 ? "Insert" : "Update") { Task { await m.saveEdit() } }.buttonStyle(.borderedProminent).tint(Color.cAccent)
            }
        }
        .padding(12)
        .background(Color.cRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cAccent.opacity(0.6), lineWidth: 1.5))
    }
}

// MARK: - Tree

struct DocTree: View {
    let doc: BDoc
    var expandAll = false
    var maxTopLevel = 1000
    var onFilter: ((String, BValue) -> Void)? = nil
    /// Turns ObjectId fields into links to the collection they name.
    var refs: ReferenceLinker? = nil
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            let fields = showAll ? doc.fields : Array(doc.fields.prefix(maxTopLevel))
            ForEach(Array(fields.enumerated()), id: \.offset) { _, f in
                TreeRow(key: f.key, path: f.key, value: f.value, depth: 0, expandAll: expandAll, onFilter: onFilter, refs: refs)
            }
            if !showAll && doc.count > maxTopLevel {
                Button("Show \(doc.count - maxTopLevel) more fields") { showAll = true }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Color.cAccent).padding(.leading, 18).padding(.top, 2)
            }
        }
    }
}

struct TreeRow: View {
    @Environment(AppState.self) private var app
    let key: String
    let path: String
    let value: BValue
    let depth: Int
    var expandAll: Bool
    var onFilter: ((String, BValue) -> Void)? = nil
    var refs: ReferenceLinker? = nil
    /// The field name used to guess a reference; array items use their array's.
    var linkKey: String? = nil
    @State private var open: Bool?
    @State private var showAllItems = false

    var body: some View {
        let isOpen = open ?? expandAll
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if value.isContainer {
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.cText3)
                        .rotationEffect(.degrees(isOpen ? 90 : 0)).frame(width: 12)
                        .animation(.snappy(duration: 0.12), value: isOpen)
                } else {
                    Spacer().frame(width: 12)
                }
                (Text(key).foregroundStyle(Color(ns: Theme.synKey)) + Text(":").foregroundStyle(Color.cText3)).font(Theme.mono)
                valueText.lineLimit(value.isContainer ? 1 : 3).textSelection(.enabled)
                if let target = refTarget, let filter = ReferenceLinker.filter(for: value) {
                    RefLink(collection: target) { app.openReference(db: refs!.db, collection: target, filter: filter) }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .contentShape(Rectangle())
            // Children appear at once; animating the insertion made the whole lazy list re-layout per frame.
            .onTapGesture { if value.isContainer { open = !isOpen } }
            .contextMenu {
                if !value.isContainer, let onFilter {
                    Button("Filter where \(path) = \(BFormat.preview(value, max: 40))") { onFilter(path, value) }
                    if let n = value.number {
                        Button("Filter where \(path) ≥ \(BFormat.number(n))") { onFilter(path, .document(["$gte": value])) }
                        Button("Filter where \(path) ≤ \(BFormat.number(n))") { onFilter(path, .document(["$lte": value])) }
                    }
                    if case .date = value { Button("Filter where \(path) after this") { onFilter(path, .document(["$gt": value])) } }
                    Button("Filter where \(path) exists") { onFilter(path, .document(["$exists": true])) }
                    Divider()
                }
                if let target = refTarget, let filter = ReferenceLinker.filter(for: value) {
                    Button("Open in \(target)") { app.openReference(db: refs!.db, collection: target, filter: filter) }
                    Divider()
                }
                Button("Copy value") { app.copy(value.isContainer ? BFormat.text(value) : BFormat.preview(value, max: 1_000_000)) }
                Button("Copy path") { app.copy(path) }
            }
            if isOpen {
                switch value {
                case .document(let d):
                    ForEach(Array(d.fields.enumerated()), id: \.offset) { _, f in TreeRow(key: f.key, path: path + "." + f.key, value: f.value, depth: depth + 1, expandAll: expandAll, onFilter: onFilter, refs: refs) }
                case .array(let a):
                    let shown = showAllItems ? min(a.count, 5000) : min(a.count, 50)
                    ForEach(0..<shown, id: \.self) { i in TreeRow(key: "\(i)", path: a[i].isContainer ? path + ".\(i)" : path, value: a[i], depth: depth + 1, expandAll: expandAll, onFilter: onFilter, refs: refs, linkKey: key) }
                    if a.count > shown {
                        Button(showAllItems ? "\(a.count - shown) more not shown" : "Show all \(Fmt.count(a.count)) items") { showAllItems = true }
                            .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(Color.cAccent)
                            .padding(.leading, CGFloat(depth + 1) * 16 + 16).disabled(showAllItems)
                    }
                default: EmptyView()
                }
            }
        }
    }

    /// The collection this value points at, when it is an ObjectId (or a list of them)
    /// under a field named like one.
    private var refTarget: String? {
        guard let refs, ReferenceLinker.isReference(value) else { return nil }
        let k = linkKey ?? key
        guard k != "_id" else { return nil }
        return refs.target(forKey: k)
    }

    @ViewBuilder private var valueText: some View {
        switch value {
        case .document(let d): Text(d.isEmpty ? "{}" : "Object · \(d.count) field\(d.count == 1 ? "" : "s")").font(Theme.mono).foregroundStyle(Color.cText3)
        case .array(let a): Text(a.isEmpty ? "[]" : "Array · \(a.count) item\(a.count == 1 ? "" : "s")").font(Theme.mono).foregroundStyle(Color.cText3)
        case .string(let s): Text("\"\(s)\"").font(Theme.mono).foregroundStyle(Color(ns: Theme.synString))
        case .date(let d):
            Text("\(DateParsing.format(d))").font(Theme.mono).foregroundStyle(Color(ns: Theme.synType))
                .help(d.formatted(date: .complete, time: .complete))
        default: Text(BFormat.text(value, pretty: false)).font(Theme.mono).foregroundStyle(Color(ns: Theme.typeColor(value)))
        }
    }
}

/// The small "→ dealerships" link after an ObjectId that names another collection.
struct RefLink: View {
    let collection: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "arrow.up.right").font(.system(size: 8.5, weight: .bold))
                Text(collection).font(.system(size: 10.5, weight: .medium))
            }
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(hover ? Color.cAccent : Color.cText3)
            .background(Color.cAccent.opacity(hover ? 0.14 : 0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Open in \(collection)")
    }
}

// MARK: - Inspector

struct DocumentInspector: View {
    @Environment(AppState.self) private var app
    @Bindable var m: DocumentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if m.editing != nil {
                InlineEditor(m: m).padding(10)
                Spacer()
            } else if let i = m.selected, m.docs.indices.contains(i) {
                let d = m.docs[i]
                HStack {
                    Text("Document").font(.system(size: 12, weight: .semibold))
                    if let id = d.id { Text(BFormat.preview(id)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.cText3).lineLimit(1) }
                    Spacer()
                    Button { app.copy(BFormat.text(d, style: .ejson), label: "Copied document") } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless)
                    if !m.session.readOnly { Button { m.beginEdit(i) } label: { Image(systemName: "pencil") }.buttonStyle(.borderless) }
                    Button { m.selected = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 12).frame(height: 38)
                Divider()
                ScrollView { DocTree(doc: d, expandAll: true, onFilter: { p, v in Task { await m.addFilter(path: p, value: v) } }, refs: app.referenceLinker(db: m.db)).padding(12) }
            }
        }
        .background(Color.cPanel)
    }
}

// MARK: - Export

enum Export {
    static func csv(_ docs: [BDoc], columns: [String], name: String) {
        func cell(_ v: BValue?) -> String {
            guard let v else { return "" }
            let s: String = v.isContainer ? BFormat.text(v, style: .ejson, pretty: false) : BFormat.preview(v, max: 100_000)
            return s.contains(",") || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = columns.joined(separator: ",") + "\n"
        for d in docs { out += columns.map { cell(d[$0]) }.joined(separator: ",") + "\n" }
        save(out, name: name + ".csv")
    }

    static func json(_ docs: [BDoc], name: String) {
        save(BFormat.text(.array(docs.map { .document($0) }), style: .ejson), name: name + ".json")
    }

    private static func save(_ text: String, name: String) {
        let p = NSSavePanel()
        p.nameFieldStringValue = name
        if p.runModal() == .OK, let url = p.url { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Live

struct LivePanel: View {
    @Bindable var m: DocumentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(m.live ? Color.cRed : Color.cText3).frame(width: 8, height: 8).symbolEffect(.pulse, isActive: m.live)
                Text(m.live ? "Live changes" : "Changes (paused)").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(m.events.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.cText3)
                Button(m.live ? "Pause" : "Resume") { m.toggleLive() }.buttonStyle(.borderless).font(.system(size: 11.5))
                Button { m.stopLive(); m.events = [] } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).frame(height: 38)
            Divider()
            if let e = m.liveError {
                Text(e).font(.system(size: 11.5)).foregroundStyle(Color.cRed).padding(12)
            }
            if m.events.isEmpty && m.liveError == nil {
                VStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 22, weight: .light)).foregroundStyle(Color.cText3)
                    Text("Waiting for inserts, updates and deletes…").font(.system(size: 12)).foregroundStyle(Color.cText3)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(m.events) { e in LiveRow(e: e).transition(.move(edge: .top).combined(with: .opacity)) }
                    }
                    .padding(10)
                    .animation(.snappy(duration: 0.25), value: m.events.first?.id)
                }
            }
        }
        .background(Color.cPanel)
    }
}

struct LiveRow: View {
    let e: ChangeEvent
    var color: Color {
        switch e.op { case "insert": return .cAccent; case "update", "replace": return .cAmber; case "delete": return .cRed; default: return .cText3 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(e.op.uppercased()).font(.system(size: 9.5, weight: .bold)).foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.14), in: Capsule())
                Text(e.key.map { BFormat.preview($0) } ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.cText3).lineLimit(1)
                Spacer()
                Text(e.at, style: .time).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Color.cText3)
            }
            if !e.fields.isEmpty {
                Text(e.fields.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(ns: Theme.synKey)).lineLimit(2)
            }
            if let d = e.doc {
                Text(BFormat.text(d, pretty: false)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.cText2).lineLimit(3)
            }
        }
        .padding(9)
        .background(Color.cRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.cHairline))
    }
}
