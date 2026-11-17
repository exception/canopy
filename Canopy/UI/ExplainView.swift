import SwiftUI

struct ExplainView: View {
    @Environment(AppState.self) private var app
    @Bindable var m: ExplainModel
    let tab: WorkspaceTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Query").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cText3)
                Text(m.queryLabel.isEmpty ? (tab.docs.filterText.isEmpty ? "{}" : tab.docs.filterText) : m.queryLabel)
                    .font(.system(size: 12, design: .monospaced)).lineLimit(1)
                if !tab.docs.sortText.isEmpty { Text("sort \(tab.docs.sortText)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.cText2) }
                Spacer()
                PillButton(title: "Explain current query", icon: "play.fill") { run() }
                if m.summary != nil {
                    Button { Task { await AIActions.explain(m) } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles").symbolEffect(.pulse, isActive: m.analysisBusy)
                            Text(m.analysisBusy ? "Analyzing…" : "Why is this slow?").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.cAI).padding(.horizontal, 11).frame(height: 28)
                        .background(Color.cAI.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }.buttonStyle(.plain).disabled(m.analysisBusy)
                }
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background(Color.cPanel)
            Rectangle().fill(Color.cHairline).frame(height: 1)
            if let e = m.error { ErrorState(message: e) }
            else if m.loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let s = m.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        verdict(s)
                        HStack(spacing: 10) {
                            Metric(title: "Returned", value: Fmt.count(s.nReturned))
                            Metric(title: "Docs examined", value: Fmt.count(s.docsExamined), warn: s.docsExamined > max(s.nReturned * 10, 1000))
                            Metric(title: "Keys examined", value: Fmt.count(s.keysExamined))
                            Metric(title: "Execution time", value: "\(s.ms) ms", warn: s.ms > 100)
                            Metric(title: "Index", value: s.indexes.first ?? "none", warn: s.indexes.isEmpty)
                        }
                        if let a = m.analysis { AIInsightCard(markdown: a) { m.analysis = nil } }
                        Text("PLAN").font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(Color.cText3)
                        if let root = s.root { PlanNode(stage: root, isRoot: true) }
                        DisclosureGroup("Raw explain output", isExpanded: $m.showRaw) {
                            CodeView(text: BFormat.text(.document(s.raw)), fontSize: 11.5).frame(height: 380).card(8)
                        }
                        .font(.system(size: 12))
                    }
                    .padding(16)
                }
                .background(Color(ns: Theme.window))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 30, weight: .light)).foregroundStyle(Color.cText3)
                    Text("See how MongoDB runs the current query: which index it uses and how much it reads.").font(.system(size: 13)).foregroundStyle(Color.cText2)
                    PillButton(title: "Explain current query", icon: "play.fill", prominent: true) { run() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if m.summary == nil && !m.loading { run() } }
    }

    private func run() {
        guard let q = try? tab.docs.buildQuery() else { return }
        Task { await m.run(query: q, label: tab.docs.filterText.isEmpty ? "{}" : tab.docs.filterText) }
    }

    private func verdict(_ s: ExplainSummary) -> some View {
        let ratio = s.nReturned == 0 ? Double(s.docsExamined) : Double(s.docsExamined) / Double(s.nReturned)
        let (icon, color, title, detail): (String, Color, String, String) = {
            if s.collscan { return ("exclamationmark.triangle.fill", .cRed, "Collection scan", "MongoDB read every document to answer this. An index on the filtered fields would fix it.") }
            if ratio > 10 { return ("exclamationmark.circle.fill", .cAmber, "Index isn't selective", "It examines \(Int(ratio))× more documents than it returns.") }
            if s.sortInMemory { return ("exclamationmark.circle.fill", .cAmber, "In-memory sort", "The index finds the documents, but the sort happens in memory. Add the sort field to the index.") }
            return ("checkmark.seal.fill", .cAccent, "Efficient", "Uses \(s.indexes.joined(separator: ", ")) and reads about as much as it returns.")
        }()
        return HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12.5)).foregroundStyle(Color.cText2)
            }
            Spacer()
        }
        .padding(14)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(0.3)))
    }
}

struct Metric: View {
    var title: String
    var value: String
    var warn = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.4).foregroundStyle(Color.cText3)
            Text(value).font(.system(size: 18, weight: .semibold).monospacedDigit()).foregroundStyle(warn ? Color.cAmber : Color.cText).lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .card(10)
    }
}

struct PlanNode: View {
    let stage: ExplainStage
    var isRoot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(stage.stage).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(color)
                        if let ms = stage.ms { Text("\(ms) ms").font(.system(size: 11)).foregroundStyle(Color.cText3) }
                    }
                    if !stage.detail.isEmpty {
                        Text(stage.detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color.cText2).lineLimit(3)
                    }
                }
                Spacer()
                HStack(spacing: 14) {
                    if let n = stage.nReturned { mini("returned", n) }
                    if let n = stage.keysExamined { mini("keys", n) }
                    if let n = stage.docsExamined { mini("docs", n) }
                }
            }
            .padding(12)
            .background(Color.cRaised, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(color.opacity(0.45)))
            ForEach(stage.children) { c in
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(Color.cHairline).frame(width: 1.5).padding(.leading, 20)
                    VStack(spacing: 0) {
                        Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.cText3).padding(.vertical, 4)
                        PlanNode(stage: c)
                    }
                    .padding(.leading, 12)
                }
            }
        }
    }

    private var color: Color {
        switch stage.stage {
        case "COLLSCAN": return .cRed
        case "SORT": return .cAmber
        case "IXSCAN", "EXPRESS_IXSCAN", "IDHACK", "EXPRESS_CLUSTERED_IXSCAN": return .cAccent
        default: return Color(ns: Theme.blue)
        }
    }

    private func mini(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(Fmt.count(n)).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
            Text(label).font(.system(size: 10)).foregroundStyle(Color.cText3)
        }
    }
}
