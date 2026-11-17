import Charts
import MapKit
import SwiftUI

struct SchemaView: View {
    @Environment(AppState.self) private var app
    @Bindable var m: SchemaModel
    let tab: WorkspaceTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Sample").font(.system(size: 12)).foregroundStyle(Color.cText2)
                Picker("", selection: $m.sampleSize) { ForEach([100, 500, 1000, 5000, 20000], id: \.self) { Text(Fmt.count($0)).tag($0) } }
                    .labelsHidden().frame(width: 90)
                Button { Task { await m.analyze() } } label: {
                    HStack(spacing: 5) {
                        if m.loading { ProgressView().controlSize(.mini) } else { Image(systemName: "waveform.path.ecg").font(.system(size: 11)) }
                        Text("Analyze").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 28)
                    .background(Color.cAccent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }.buttonStyle(.plain)
                if let r = m.report {
                    Text("\(Fmt.count(r.sampled)) documents · \(r.fields.count) fields · \(Fmt.ms(r.elapsed))").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(Color.cText3)
                }
                Spacer()
                if m.report != nil {
                    Button { Task { await AIActions.validator(m) } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.shield").symbolEffect(.pulse, isActive: m.validatorBusy)
                            Text(m.validatorBusy ? "Writing…" : "Generate validator").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.cAI).padding(.horizontal, 11).frame(height: 28)
                        .background(Color.cAI.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }.buttonStyle(.plain).disabled(m.validatorBusy)
                    Button { Task { await AIActions.schemaInsight(m) } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles").symbolEffect(.pulse, isActive: m.insightBusy)
                            Text(m.insightBusy ? "Reviewing…" : "Review with Claude").font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.cAI).padding(.horizontal, 11).frame(height: 28)
                        .background(Color.cAI.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }.buttonStyle(.plain).disabled(m.insightBusy)
                }
            }
            .padding(.horizontal, 16).frame(height: 48)
            .background(Color.cPanel)
            Rectangle().fill(Color.cHairline).frame(height: 1)
            if let e = m.error { ErrorState(message: e) }
            else if let r = m.report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let insight = m.insight {
                            AIInsightCard(markdown: insight) { m.insight = nil }
                        }
                        if m.validator != nil { ValidatorCard(m: m) }
                        VStack(spacing: 0) {
                            HStack {
                                Text("FIELD").frame(maxWidth: .infinity, alignment: .leading)
                                Text("TYPES").frame(width: 300, alignment: .leading)
                                Text("PRESENT").frame(width: 120, alignment: .trailing)
                            }
                            .font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(Color.cText3)
                            .padding(.horizontal, 14).frame(height: 30)
                            Divider()
                            ForEach(r.fields) { f in
                                FieldRow(f: f, report: r, expanded: m.expanded == f.path) {
                                    withAnimation(.snappy(duration: 0.2)) { m.expanded = m.expanded == f.path ? nil : f.path }
                                } onFilter: { value in
                                    tab.docs.filterText = "{ \(BFormat.isIdentifier(f.path) || f.path.contains(".") && !f.path.contains(" ") ? f.path : BFormat.quote(f.path)): \(value) }"
                                    tab.mode = .documents
                                    Task { await tab.docs.run() }
                                }
                                Divider().opacity(0.6)
                            }
                        }
                        .card(10)
                    }
                    .padding(14)
                }
                .background(Color(ns: Theme.window))
            } else if m.loading {
                ProgressView("Sampling \(Fmt.count(m.sampleSize)) documents…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 30, weight: .light)).foregroundStyle(Color.cText3)
                    Text("See every field, its types, and how values are distributed").font(.system(size: 13)).foregroundStyle(Color.cText2)
                    PillButton(title: "Analyze schema", icon: "waveform.path.ecg", prominent: true) { Task { await m.analyze() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { if m.report == nil && !m.loading { await m.analyze() } }
    }
}

struct AIInsightCard: View {
    var markdown: String
    var onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Claude's review", systemImage: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.cAI)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            MarkdownText(markdown)
        }
        .padding(14)
        .background(Color.cAI.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cAI.opacity(0.25)))
    }
}

struct FieldRow: View {
    let f: SchemaField
    let report: SchemaReport
    let expanded: Bool
    var toggle: () -> Void
    var onFilter: (String) -> Void
    @State private var hover = false

    var body: some View {
        let presence = report.presence(f)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(Color.cText3)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(f.name).font(.system(size: 12.5, weight: f.depth == 0 ? .semibold : .regular, design: .monospaced))
                    if f.isMixed {
                        Text("MIXED").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.cAmber)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Color.cAmber.opacity(0.14), in: Capsule())
                    }
                }
                .padding(.leading, CGFloat(f.depth) * 18)
                .frame(maxWidth: .infinity, alignment: .leading)
                TypeBar(types: f.types).frame(width: 300, alignment: .leading)
                HStack(spacing: 8) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.cPill)
                            Capsule().fill(presence < 0.999 ? Color.cAmber : Color.cAccent).frame(width: g.size.width * presence)
                        }
                    }.frame(width: 50, height: 5)
                    Text("\(Int((presence * 100).rounded()))%").font(.system(size: 11.5, weight: .medium).monospacedDigit()).foregroundStyle(Color.cText2).frame(width: 38, alignment: .trailing)
                }
                .frame(width: 120, alignment: .trailing)
            }
            .padding(.horizontal, 14).frame(height: 32)
            .background(hover ? Color(ns: Theme.hover) : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .onHover { hover = $0 }
            if expanded { FieldDetail(f: f, onFilter: onFilter).padding(.leading, 14 + CGFloat(f.depth) * 18 + 14).padding(.trailing, 14).padding(.bottom, 12) }
        }
    }
}

struct TypeBar: View {
    let types: [String: Int]
    var body: some View {
        let total = max(types.values.reduce(0, +), 1)
        let sorted = types.sorted { $0.value > $1.value }
        HStack(spacing: 8) {
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(sorted, id: \.key) { k, v in
                        Theme.typeColor(name: k).frame(width: max(3, g.size.width * CGFloat(v) / CGFloat(total) - 1.5))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(width: 90, height: 6)
            Text(sorted.prefix(3).map { $0.key }.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Color.cText2).lineLimit(1)
        }
    }
}

struct FieldDetail: View {
    let f: SchemaField
    var onFilter: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                ForEach(f.types.sorted { $0.value > $1.value }, id: \.key) { k, v in
                    HStack(spacing: 5) {
                        Circle().fill(Theme.typeColor(name: k)).frame(width: 7, height: 7)
                        Text("\(k) \(Int((Double(v) / Double(max(f.total, 1)) * 100).rounded()))%").font(.system(size: 11.5)).foregroundStyle(Color.cText2)
                    }
                }
            }
            if !f.points.isEmpty {
                GeoMap(points: f.points)
            } else if !f.dates.isEmpty {
                DateHistogram(dates: f.dates)
            } else if f.numbers.count > 5 && f.distinct > 12 {
                NumberHistogram(values: f.numbers)
            } else if !f.topValues.isEmpty {
                TopValues(values: f.topValues, total: f.presence, onFilter: onFilter)
            } else if !f.lengths.isEmpty {
                Text("Array length \(f.lengths.min() ?? 0)–\(f.lengths.max() ?? 0), average \(String(format: "%.1f", Double(f.lengths.reduce(0, +)) / Double(f.lengths.count)))")
                    .font(.system(size: 11.5)).foregroundStyle(Color.cText2)
            }
            if !f.sampleValues.isEmpty && f.dates.isEmpty && f.topValues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(f.sampleValues.prefix(4).enumerated()), id: \.offset) { _, v in
                        Text(BFormat.text(v, pretty: false)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color(ns: Theme.typeColor(v))).lineLimit(1)
                    }
                }
            }
        }
    }
}

struct TopValues: View {
    let values: [(String, Int)]
    let total: Int
    var onFilter: (String) -> Void

    var body: some View {
        let maxV = values.map(\.1).max() ?? 1
        VStack(alignment: .leading, spacing: 4) {
            ForEach(values.prefix(8), id: \.0) { v, n in
                HStack(spacing: 8) {
                    Text(v).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).frame(width: 170, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3).fill(Color.cAccent.opacity(0.75)).frame(width: max(2, g.size.width * CGFloat(n) / CGFloat(maxV)))
                    }.frame(height: 12)
                    Text("\(Int((Double(n) / Double(max(total, 1)) * 100).rounded()))%").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.cText3).frame(width: 36, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    let lit: String = ["true", "false", "null"].contains(v) || Int(v) != nil ? v : BFormat.quote(v)
                    onFilter(lit)
                }
                .help("Filter documents by this value")
            }
        }
        .frame(maxWidth: 520)
    }
}

struct NumberHistogram: View {
    let values: [Double]
    var body: some View {
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let n = 24
        let w = max((hi - lo) / Double(n), 1e-9)
        var bins = Array(repeating: 0, count: n)
        for v in values { bins[min(n - 1, Int((v - lo) / w))] += 1 }
        return VStack(alignment: .leading, spacing: 4) {
            Chart(Array(bins.enumerated()), id: \.offset) { i, c in
                BarMark(x: .value("v", lo + Double(i) * w), y: .value("n", c), width: .ratio(0.85)).foregroundStyle(Color.cAccent.gradient)
            }
            .chartYAxis(.hidden)
            .frame(height: 90)
            Text("min \(BFormat.number(lo)) · max \(BFormat.number(hi)) · mean \(BFormat.number((values.reduce(0, +) / Double(values.count) * 100).rounded() / 100))")
                .font(.system(size: 11)).foregroundStyle(Color.cText3)
        }
        .frame(maxWidth: 560)
    }
}

struct DateHistogram: View {
    let dates: [Date]
    var body: some View {
        let lo = dates.min()!, hi = dates.max()!
        let n = 30
        let span = max(hi.timeIntervalSince(lo), 1)
        var bins = Array(repeating: 0, count: n)
        for d in dates { bins[min(n - 1, Int(d.timeIntervalSince(lo) / span * Double(n)))] += 1 }
        return VStack(alignment: .leading, spacing: 4) {
            Chart(Array(bins.enumerated()), id: \.offset) { i, c in
                BarMark(x: .value("t", lo.addingTimeInterval(span * Double(i) / Double(n))), y: .value("n", c), width: .ratio(0.85))
                    .foregroundStyle(Color.cAmber.gradient)
            }
            .chartYAxis(.hidden)
            .frame(height: 90)
            Text("\(lo.formatted(date: .abbreviated, time: .omitted)) → \(hi.formatted(date: .abbreviated, time: .omitted))")
                .font(.system(size: 11)).foregroundStyle(Color.cText3)
        }
        .frame(maxWidth: 560)
    }
}

/// Markdown block rendering (paragraphs, bullets, bold, code, tables-as-text).
struct MarkdownText: View {
    let text: String
    init(_ t: String) { text = t }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .code(let c):
                    Text(c).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cField, in: RoundedRectangle(cornerRadius: 6))
                case .bullet(let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Color.cText3)
                        inline(s)
                    }
                case .heading(let s): inline(s).font(.system(size: 13, weight: .semibold))
                case .table(let rows): TableBlock(rows: rows)
                case .para(let s): inline(s)
                }
            }
        }
        .font(.system(size: 12.5))
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(s)
    }

    enum Block { case para(String), bullet(String), code(String), heading(String), table([[String]]) }

    private var blocks: [Block] {
        var out: [Block] = []
        var code: [String]? = nil
        var table: [[String]] = []
        func flushTable() { if !table.isEmpty { out.append(.table(table)); table = [] } }
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flushTable(); code = [] }
                continue
            }
            if code != nil { code!.append(line); continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") {
                let cells = t.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
                continue
            }
            flushTable()
            if t.isEmpty { continue }
            if t.hasPrefix("- ") || t.hasPrefix("* ") { out.append(.bullet(String(t.dropFirst(2)))) }
            else if let r = t.range(of: #"^\d+\. "#, options: .regularExpression) { out.append(.bullet(String(t[r.upperBound...]))) }
            else if t.hasPrefix("#") { out.append(.heading(t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))) }
            else { out.append(.para(t)) }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushTable()
        return out
    }
}

struct TableBlock: View {
    let rows: [[String]]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                GridRow {
                    ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                        Text((try? AttributedString(markdown: c)) ?? AttributedString(c))
                            .font(.system(size: 12, weight: i == 0 ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(i == 0 ? Color.cText2 : Color.cText)
                    }
                }
                if i == 0 { Divider() }
            }
        }
        .padding(10)
        .background(Color.cField, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct GeoMap: View {
    let points: [(Double, Double)]
    @State private var tick = 0

    private var region: MKCoordinateRegion {
        let lats = points.map(\.1), lngs = points.map(\.0)
        let (minLat, maxLat, minLng, maxLng) = (lats.min()!, lats.max()!, lngs.min()!, lngs.max()!)
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLng + maxLng) / 2),
                                  span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.5), longitudeDelta: max((maxLng - minLng) * 1.4, 0.5)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MapReader { proxy in
                Map(initialPosition: .region(region))
                    .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                    .onMapCameraChange(frequency: .continuous) { tick += 1 }
                    .overlay {
                        Canvas { ctx, _ in
                            _ = tick
                            for p in points.prefix(1500) {
                                guard let pt = proxy.convert(CLLocationCoordinate2D(latitude: p.1, longitude: p.0), to: .local) else { continue }
                                let r = CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)
                                ctx.fill(Path(ellipseIn: r), with: .color(Color(ns: Theme.hex(0x3DD68C, 0.7))))
                                ctx.stroke(Path(ellipseIn: r), with: .color(.white.opacity(0.55)), lineWidth: 0.6)
                            }
                        }
                        .allowsHitTesting(false)
                    }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text("\(Fmt.count(points.count)) points in the sample").font(.system(size: 11)).foregroundStyle(Color.cText3)
        }
        .frame(maxWidth: 620)
    }
}

struct ValidatorCard: View {
    @Environment(AppState.self) private var app
    @Bindable var m: SchemaModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Suggested validator", systemImage: "checkmark.shield").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.cAI)
                Spacer()
                if let cur = m.currentValidator { Text(cur.isEmpty ? "No validator today" : "Replaces the current validator").font(.system(size: 11)).foregroundStyle(Color.cText3) }
                Button { m.validator = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            if let n = m.validatorNote { MarkdownText(n) }
            CodeEditor(text: Binding(get: { m.validator ?? "" }, set: { m.validator = $0 }))
                .frame(height: 240).background(Color.cField, in: RoundedRectangle(cornerRadius: 7))
            if let e = m.validatorError { Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(Color.cRed).textSelection(.enabled) }
            HStack {
                Picker("Level", selection: $m.validationLevel) { Text("moderate").tag("moderate"); Text("strict").tag("strict") }.frame(width: 170)
                Picker("Action", selection: $m.validationAction) { Text("warn").tag("warn"); Text("error").tag("error") }.frame(width: 150)
                Spacer()
                Button { app.copy("db.runCommand({ collMod: \"\(m.collection)\", validator: \(m.validator ?? "{}"), validationLevel: \"\(m.validationLevel)\", validationAction: \"\(m.validationAction)\" })") } label: { Label("Copy command", systemImage: "doc.on.doc") }.buttonStyle(.borderless)
                if !m.session.readOnly {
                    Button("Apply to collection") { Task { await m.applyValidator(app: app) } }.buttonStyle(.borderedProminent).tint(Color.cAI)
                }
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .background(Color.cAI.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cAI.opacity(0.25)))
    }
}
