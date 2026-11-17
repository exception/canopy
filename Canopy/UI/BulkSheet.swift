import SwiftUI

@MainActor @Observable
final class BulkModel {
    enum Kind { case update, delete }
    let session: Session
    let db: String
    let collection: String
    var kind: Kind
    var filterText: String
    var updateText = "{\n  $set: {\n    \n  }\n}"
    var matching: Int?
    var sample: [BDoc] = []
    var counting = false
    var running = false
    var error: String?
    var result: String?
    var askText = ""
    var askBusy = false
    var askNote: String?
    var askError: String?

    init(session: Session, db: String, collection: String, kind: Kind, filter: String) {
        self.session = session; self.db = db; self.collection = collection; self.kind = kind; self.filterText = filter
    }

    func preview() async {
        counting = true
        defer { counting = false }
        do {
            let f = try ShellParser.parseDocument(filterText)
            matching = try await session.service.count(db: db, collection: collection, filter: f, maxTimeMS: 15_000)
            var q = FindQuery(); q.filter = f; q.limit = 3
            sample = try await session.service.find(db: db, collection: collection, query: q).documents
            error = nil
        } catch { self.error = error.localizedDescription; matching = nil; sample = [] }
    }

    func execute() async -> Bool {
        guard !session.readOnly else { error = "This connection is read-only."; return false }
        running = true
        defer { running = false }
        do {
            let f = try ShellParser.parseDocument(filterText)
            if kind == .delete {
                let n = try await session.service.deleteMany(db: db, collection: collection, filter: f)
                result = "Deleted \(Fmt.count(n)) documents"
            } else {
                let u = try ShellParser.parse(updateText)
                if case .document(let d) = u, !(d.keys.first?.hasPrefix("$") ?? false) {
                    error = "Use update operators like { $set: { … } }, or a pipeline [ … ]. Replacing whole documents isn't allowed here."
                    return false
                }
                let (n, mod) = try await session.service.updateMany(db: db, collection: collection, filter: f, update: u)
                result = "Matched \(Fmt.count(n)), modified \(Fmt.count(mod))"
            }
            Task { await session.refreshStat(db, collection) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct BulkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Bindable var m: BulkModel
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: m.kind == .delete ? "trash" : "pencil.and.list.clipboard").foregroundStyle(m.kind == .delete ? Color.cRed : Color.cAccent)
                Text(m.kind == .delete ? "Delete many in \(m.collection)" : "Update many in \(m.collection)").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("", selection: $m.kind) { Text("Update").tag(BulkModel.Kind.update); Text("Delete").tag(BulkModel.Kind.delete) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 160)
            }
            if m.kind == .update {
                AskBar(text: $m.askText, placeholder: "Describe the change — e.g. \u{201C}mark processing orders older than 30 days as cancelled\u{201D}",
                       busy: m.askBusy, note: m.askNote, error: m.askError) { Task { await AIActions.update(m) } }
            }
            Text("Filter").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cText3)
            CodeEditor(text: $m.filterText, placeholder: "{ } matches every document", onSubmit: { Task { await m.preview() } })
                .frame(height: 64).background(Color.cField, in: RoundedRectangle(cornerRadius: 7))
                .onChange(of: m.filterText) { Task { try? await Task.sleep(for: .milliseconds(400)); await m.preview() } }
            if m.kind == .update {
                Text("Update").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cText3)
                CodeEditor(text: $m.updateText).frame(height: 120).background(Color.cField, in: RoundedRectangle(cornerRadius: 7))
            }
            HStack(spacing: 8) {
                if m.counting { ProgressView().controlSize(.small) }
                if let n = m.matching {
                    Label("\(Fmt.count(n)) document\(n == 1 ? "" : "s") match", systemImage: "doc.on.doc")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(n == 0 ? Color.cText3 : (m.kind == .delete ? Color.cRed : Color.cText))
                }
                Spacer()
            }
            if !m.sample.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(m.sample.enumerated()), id: \.offset) { _, d in
                        Text(BFormat.text(d, pretty: false)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.cText2).lineLimit(1)
                    }
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color.cField, in: RoundedRectangle(cornerRadius: 7))
            }
            if let e = m.error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Color.cRed).textSelection(.enabled) }
            HStack {
                if m.session.readOnly { Label("Read-only connection", systemImage: "lock.fill").font(.system(size: 11.5)).foregroundStyle(Color.cAmber) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    Task {
                        if await m.execute() {
                            app.flash(m.result ?? "Done")
                            onDone()
                            dismiss()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(m.kind == .delete ? Color.cRed : Color.cAccent)
                .disabled(m.running || m.matching == nil || m.matching == 0 || m.session.readOnly)
            }
        }
        .padding(20).frame(width: 640)
        .task { await m.preview() }
    }

    private var actionTitle: String {
        let n = m.matching.map { Fmt.count($0) } ?? "…"
        return m.kind == .delete ? "Delete \(n) documents" : "Update \(n) documents"
    }
}

extension BulkModel: Identifiable { nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) } }
