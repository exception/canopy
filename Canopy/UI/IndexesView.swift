import SwiftUI

struct IndexesView: View {
    @Environment(AppState.self) private var app
    @Bindable var m: IndexesModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("\(m.indexes.count) indexes").font(.system(size: 12.5, weight: .medium))
                if m.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await AIActions.suggestIndexes(m) } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").symbolEffect(.pulse, isActive: m.suggestBusy)
                        Text(m.suggestBusy ? "Thinking…" : "Suggest indexes").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.cAI).padding(.horizontal, 11).frame(height: 28)
                    .background(Color.cAI.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }.buttonStyle(.plain).disabled(m.suggestBusy)
                if !m.session.readOnly { PillButton(title: "Create index", icon: "plus") { m.creating = true } }
                Button { Task { await m.load() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background(Color.cPanel)
            Rectangle().fill(Color.cHairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let e = m.error { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Color.cRed).font(.system(size: 12)) }
                    if !m.suggestions.isEmpty || m.suggestNote != nil { suggestions }
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text("NAME").frame(width: 220, alignment: .leading)
                            Text("KEYS").frame(maxWidth: .infinity, alignment: .leading)
                            Text("TYPE").frame(width: 120, alignment: .leading)
                            Text("SIZE").frame(width: 80, alignment: .trailing)
                            Text("USAGE").frame(width: 150, alignment: .trailing)
                            Spacer().frame(width: 40)
                        }
                        .font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(Color.cText3)
                        .padding(.horizontal, 14).frame(height: 30)
                        Divider()
                        ForEach(m.indexes) { ix in IndexRow(m: m, ix: ix); Divider().opacity(0.6) }
                    }
                    .card(10)
                }
                .padding(14)
            }
            .background(Color(ns: Theme.window))
        }
        .task { if m.indexes.isEmpty { await m.load() } }
        .sheet(isPresented: $m.creating) { CreateIndexSheet(m: m, keys: m.newKeys, options: m.newOptions) }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Claude's suggestions", systemImage: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.cAI)
                Spacer()
                Button { m.suggestions = []; m.suggestNote = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            if let n = m.suggestNote { MarkdownText(n) }
            ForEach(m.suggestions) { s in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.keys + (s.options.isEmpty ? "" : "  " + s.options)).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        Text(s.reason).font(.system(size: 12)).foregroundStyle(Color.cText2)
                    }
                    Spacer()
                    if !m.session.readOnly {
                        PillButton(title: "Create…", icon: "plus") {
                            m.newKeys = s.keys
                            m.newOptions = s.options.isEmpty ? "{ }" : s.options
                            m.creating = true
                        }
                    }
                }
                .padding(10).background(Color.cRaised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(14)
        .background(Color.cAI.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cAI.opacity(0.25)))
    }
}

struct IndexRow: View {
    @Bindable var m: IndexesModel
    let ix: IndexInfo
    @State private var hover = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: ix.name == "_id_" ? "key.fill" : "bolt.horizontal.fill").font(.system(size: 10)).foregroundStyle(ix.name == "_id_" ? Color.cAmber : Color.cAccent)
                Text(ix.name).font(.system(size: 12.5, weight: .medium, design: .monospaced)).lineLimit(1)
            }
            .frame(width: 220, alignment: .leading)
            HStack(spacing: 4) {
                ForEach(Array(ix.keys.fields.enumerated()), id: \.offset) { _, f in
                    HStack(spacing: 3) {
                        Text(f.key).font(.system(size: 11.5, design: .monospaced))
                        Text(direction(f.value)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.cText3)
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.cPill, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Tag(ix.kind)
                if ix.unique { Tag("unique", color: .cAmber) }
                if ix.ttl != nil { Tag("ttl") }
                if ix.partial != nil { Tag("partial") }
                if ix.sparse { Tag("sparse") }
                if ix.hidden { Tag("hidden") }
            }
            .frame(width: 120, alignment: .leading)
            Text(Fmt.bytes(ix.size)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.cText2).frame(width: 80, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 1) {
                Text(ix.ops.map { "\(Fmt.count($0)) ops" } ?? "—").font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(ix.ops == 0 && ix.name != "_id_" ? Color.cAmber : Color.cText2)
                if let s = ix.since { Text("since \(s.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(Color.cText3) }
            }
            .frame(width: 150, alignment: .trailing)
            ZStack {
                Color.clear
                if ix.name != "_id_" && !m.session.readOnly {
                    Button { confirmDrop() } label: { Image(systemName: "trash").foregroundStyle(Color.cRed) }.buttonStyle(.borderless).opacity(hover ? 1 : 0)
                }
            }.frame(width: 40, height: 30)
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(hover ? Color(ns: Theme.hover) : .clear)
        .onHover { hover = $0 }
    }

    private func direction(_ v: BValue) -> String {
        if let n = v.number { return n > 0 ? "↑" : "↓" }
        return v.stringValue ?? ""
    }

    private func confirmDrop() {
        let a = NSAlert()
        a.messageText = "Drop index \(ix.name)?"
        a.informativeText = "Queries that use it will fall back to other indexes or a collection scan."
        a.addButton(withTitle: "Drop")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { Task { await m.drop(ix.name) } }
    }
}

struct Tag: View {
    var text: String
    var color: Color = .cText2
    init(_ t: String, color: Color = .cText2) { text = t; self.color = color }
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2).background(color.opacity(0.12), in: Capsule())
    }
}

struct CreateIndexSheet: View {
    @Bindable var m: IndexesModel
    @Environment(\.dismiss) private var dismiss
    @State var keys: String
    @State var options: String
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create index on \(m.collection)").font(.system(size: 15, weight: .semibold))
            Text("Keys").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.cText3)
            CodeEditor(text: $keys).frame(height: 70).background(Color.cField, in: RoundedRectangle(cornerRadius: 7))
            Text("Options — e.g. { unique: true, name: \"…\", expireAfterSeconds: 3600, partialFilterExpression: { … } }").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.cText3)
            CodeEditor(text: $options).frame(height: 70).background(Color.cField, in: RoundedRectangle(cornerRadius: 7))
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Color.cRed) }
            HStack {
                Text("Built in the background on MongoDB 4.2+.").font(.system(size: 11)).foregroundStyle(Color.cText3)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    busy = true
                    Task {
                        error = await m.create(keys: keys, options: options)
                        busy = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(20).frame(width: 520)
    }
}
