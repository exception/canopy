import SwiftUI

struct AggregationView: View {
    @Environment(AppState.self) private var app
    @Bindable var m: AggregationModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                AskBar(text: $m.askText, placeholder: "Describe a pipeline — e.g. \u{201C}revenue by month and payment method, delivered orders only\u{201D}",
                       busy: m.askBusy, note: m.askNote, error: m.askError) { Task { await AIActions.pipeline(m) } }
                HStack(spacing: 8) {
                    Text("\(m.stages.filter(\.enabled).count) stage\(m.stages.count == 1 ? "" : "s")").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.cText2)
                    Toggle("Text", isOn: Binding(get: { m.textMode }, set: { on in
                        if on { m.pipelineText = m.pipelineShell } else { try? m.syncFromText() }
                        m.textMode = on
                    }))
                    .toggleStyle(.switch).controlSize(.mini)
                    Spacer()
                    Menu {
                        Button("Copy as mongosh") { app.copy("db.getSiblingDB(\"\(m.db)\").\(m.collection).aggregate(\(m.pipelineShell))") }
                        Button("Copy as Node.js") { app.copy(CodeExport.node(db: m.db, coll: m.collection, pipeline: m.pipelineShell)) }
                        Button("Copy as Python (PyMongo)") { app.copy(CodeExport.python(db: m.db, coll: m.collection, pipeline: (try? m.pipeline()) ?? [])) }
                        Button("Copy as Extended JSON") { app.copy(BFormat.text(.array((try? m.pipeline()) ?? []), style: .ejson)) }
                    } label: { Label("Export", systemImage: "chevron.left.forwardslash.chevron.right").font(.system(size: 12)) }
                        .menuStyle(.borderlessButton).fixedSize()
                    PillButton(title: "Previews", icon: "eye") { Task { await m.refreshPreviews() } }
                    Button { Task { await m.refreshPreviews(); await m.run() } } label: {
                        HStack(spacing: 5) {
                            if m.running { ProgressView().controlSize(.mini) } else { Image(systemName: "play.fill").font(.system(size: 10)) }
                            Text("Run").font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 28)
                        .background(Color.cAccent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.cPanel)
            Rectangle().fill(Color.cHairline).frame(height: 1)
            HSplitView {
                Group {
                    if m.textMode {
                        CodeEditor(text: $m.pipelineText, placeholder: "[{ $match: { … } }]")
                            .padding(10)
                    } else {
                        stageList
                    }
                }
                .frame(minWidth: 420, idealWidth: 640)
                results.frame(minWidth: 300, idealWidth: 460)
            }
        }
        .onAppear { if m.stages.isEmpty { m.add("$match") } }
    }

    private var stageList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(m.stages.enumerated()), id: \.element.id) { i, s in
                    StageCard(m: m, stage: s, index: i)
                    Button { withAnimation(.snappy) { m.add("$match", at: i + 1) } } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.cText3)
                            .frame(width: 22, height: 22).background(Color.cPill, in: Circle())
                    }
                    .buttonStyle(.plain).padding(.vertical, 4).help("Add stage here")
                }
                if m.stages.isEmpty {
                    PillButton(title: "Add stage", icon: "plus") { m.add() }.padding(20)
                }
            }
            .padding(14)
        }
        .background(Color(ns: Theme.window))
    }

    private var results: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Output").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !m.results.isEmpty {
                    Text("\(m.results.count)\(m.results.count == 200 ? "+" : "") docs · \(Fmt.ms(m.resultsElapsed))").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.cText3)
                }
            }
            .padding(.horizontal, 14).frame(height: 36)
            Divider()
            if let e = m.error {
                ErrorState(message: e)
            } else if m.results.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 24, weight: .light)).foregroundStyle(Color.cText3)
                    Text("Run the pipeline to see its output").font(.system(size: 12)).foregroundStyle(Color.cText3)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(m.results.enumerated()), id: \.offset) { _, d in
                            DocTree(doc: d, expandAll: d.count <= 6, maxTopLevel: 20).padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading).card()
                        }
                    }.padding(12)
                }
            }
        }
        .background(Color.cPanel)
    }
}

struct StageCard: View {
    @Bindable var m: AggregationModel
    @Bindable var stage: PipelineStage
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("\(index + 1)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Color.cText3)
                    .frame(width: 20, height: 20).background(Color.cPill, in: Circle())
                Menu {
                    ForEach(PipelineStage.operators, id: \.self) { op in
                        Button(op) {
                            stage.op = op
                            stage.body = PipelineStage.template(op)
                        }
                    }
                } label: {
                    Text(stage.op).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Color(ns: Theme.synOperator))
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if stage.previewLoading { ProgressView().controlSize(.mini) }
                else if stage.previewError == nil && !stage.preview.isEmpty {
                    Text("\(stage.preview.count) sample doc\(stage.preview.count == 1 ? "" : "s") · \(Fmt.ms(stage.previewElapsed))").font(.system(size: 11)).foregroundStyle(Color.cText3)
                }
                Toggle("", isOn: $stage.enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden().help("Enable stage")
                Button { stage.collapsed.toggle() } label: { Image(systemName: stage.collapsed ? "chevron.down" : "chevron.up") }.buttonStyle(.borderless)
                Button { withAnimation(.snappy) { m.stages.removeAll { $0.id == stage.id } } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 12).frame(height: 40)
            if !stage.collapsed {
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    CodeEditor(text: $stage.body, onSubmit: { Task { await m.refreshPreviews() } })
                        .frame(height: CGFloat(min(max(stage.body.split(separator: "\n", omittingEmptySubsequences: false).count, 2), 18)) * 16 + 16)
                        .padding(6)
                        .frame(maxWidth: .infinity)
                    Rectangle().fill(Color.cHairline).frame(width: 1)
                    preview.frame(width: 250)
                }
            }
        }
        .background(Color.cRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cHairline))
        .opacity(stage.enabled ? 1 : 0.55)
    }

    @ViewBuilder private var preview: some View {
        if let e = stage.previewError {
            Text(e).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.cRed).padding(10).frame(maxWidth: .infinity, alignment: .leading)
        } else if stage.preview.isEmpty {
            Text(stage.previewLoading ? "" : "No output yet").font(.system(size: 11)).foregroundStyle(Color.cText3).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(stage.preview.prefix(3).enumerated()), id: \.offset) { _, d in
                        Text(BFormat.text(d, pretty: false))
                            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.cText2).lineLimit(4)
                            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.cField, in: RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(8)
            }
            .frame(maxHeight: 220)
        }
    }
}

enum CodeExport {
    static func node(db: String, coll: String, pipeline: String) -> String {
        """
        const { MongoClient, ObjectId } = require("mongodb");
        const client = new MongoClient(process.env.MONGODB_URI);
        const docs = await client.db("\(db)").collection("\(coll)").aggregate(\(pipeline)).toArray();
        """
    }

    static func python(db: String, coll: String, pipeline: [BValue]) -> String {
        func py(_ v: BValue) -> String {
            switch v {
            case .document(let d): return "{" + d.fields.map { "\(BFormat.quote($0.key)): \(py($0.value))" }.joined(separator: ", ") + "}"
            case .array(let a): return "[" + a.map(py).joined(separator: ", ") + "]"
            case .bool(let b): return b ? "True" : "False"
            case .null, .undefined: return "None"
            case .objectId(let h): return "ObjectId(\"\(h)\")"
            case .date(let d): return "datetime.fromisoformat(\"\(DateParsing.format(d).replacingOccurrences(of: "Z", with: "+00:00"))\")"
            case .decimal(let s): return "Decimal128(\"\(s)\")"
            case .regex(let p, let f): return "re.compile(\(BFormat.quote(p))\(f.contains("i") ? ", re.I" : ""))"
            default: return BFormat.text(v, style: .ejson, pretty: false)
            }
        }
        return """
        from pymongo import MongoClient
        from bson import ObjectId, Decimal128
        from datetime import datetime
        import os, re
        client = MongoClient(os.environ["MONGODB_URI"])
        docs = list(client["\(db)"]["\(coll)"].aggregate(\(py(.array(pipeline)))))
        """
    }
}
