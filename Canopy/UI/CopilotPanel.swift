import SwiftUI

struct CopilotPanel: View {
    @Environment(AppState.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var c = app.copilot
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Color.cAI)
                Text("Claude").font(.system(size: 13, weight: .semibold))
                Text("read-only access").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.cText3)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.cPill, in: Capsule())
                Spacer()
                if !c.messages.isEmpty {
                    Button { c.reset() } label: { Image(systemName: "square.and.pencil") }.buttonStyle(.borderless).help("New conversation")
                }
                Button { app.showCopilot = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).frame(height: 44)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if c.messages.isEmpty { welcome(c) }
                        ForEach(c.messages) { msg in
                            MessageView(msg: msg, busy: c.busy && msg.id == c.messages.last?.id).id(msg.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .onChange(of: c.messages) { withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField(app.session == nil ? "Connect to ask about your data" : "Ask about your data…", text: $c.input, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { c.send() }
                    .disabled(app.session == nil)
                if c.busy {
                    Button { c.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 20)).foregroundStyle(Color.cText2) }.buttonStyle(.plain)
                } else {
                    Button { c.send() } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)).foregroundStyle(c.input.isEmpty ? Color.cText3 : Color.cAI)
                    }
                    .buttonStyle(.plain).disabled(c.input.isEmpty)
                }
            }
            .padding(10)
            .background(Color.cField, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(focused ? Color.cAI.opacity(0.4) : Color.cHairline))
            .padding(10)
        }
        .background(Color.cPanel)
        .onAppear { focused = true }
    }

    private func welcome(_ c: CopilotModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask anything about your data").font(.system(size: 15, weight: .semibold))
            Text("Claude can look at schemas, run read-only queries and aggregations, check indexes and explain plans on this connection, then hand you queries to apply.")
                .font(.system(size: 12)).foregroundStyle(Color.cText2)
            if !ClaudeCLI.isAvailable {
                Label("Needs Claude Code installed (claude.com/code). Set its path in Settings if it's somewhere unusual.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5)).foregroundStyle(Color.cAmber)
            }
            ForEach(c.suggestions, id: \.self) { s in
                Button { c.send(s) } label: {
                    HStack {
                        Text(s).font(.system(size: 12)).multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Color.cText3)
                    }
                    .padding(10).background(Color.cRaised, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.cHairline))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct MessageView: View {
    @Environment(AppState.self) private var app
    let msg: CopilotMessage
    let busy: Bool

    var body: some View {
        if msg.role == "user" {
            HStack {
                Spacer(minLength: 40)
                Text(textOf(msg)).font(.system(size: 12.5)).textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(Color.cAI.opacity(0.13), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(msg.parts) { part in
                    switch part {
                    case .text(_, let t): MarkdownText(t)
                    case .tool(let t): ToolChip(call: t)
                    case .proposal(let p): ProposalCard(p: p)
                    }
                }
                if busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(msg.parts.isEmpty ? "Thinking…" : "Working…").font(.system(size: 11.5)).foregroundStyle(Color.cText3)
                    }
                }
                if let e = msg.error { Label(e, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(Color.cRed).textSelection(.enabled) }
                if let cost = msg.cost, !busy {
                    Text(String(format: "$%.3f", cost)).font(.system(size: 10)).foregroundStyle(Color.cText3)
                }
            }
        }
    }

    private func textOf(_ m: CopilotMessage) -> String {
        m.parts.compactMap { if case .text(_, let t) = $0 { return t }; return nil }.joined(separator: "\n")
    }
}

struct ToolChip: View {
    @Environment(AppState.self) private var app
    let call: ToolCall

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Group {
                    if call.result == nil { ProgressView().controlSize(.mini) }
                    else { Image(systemName: call.isError ? "xmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(call.isError ? Color.cRed : Color.cAccent) }
                }
                .frame(width: 14)
                Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(Color.cText3)
                Text(call.label).font(.system(size: 11.5, weight: .medium))
                Text(summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.cText3).lineLimit(1)
                Spacer(minLength: 0)
                if let f = call.finished { Text(Fmt.ms(f.timeIntervalSince(call.started))).font(.system(size: 10)).foregroundStyle(Color.cText3) }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Color.cText3).rotationEffect(.degrees(call.expanded ? 90 : 0))
            }
            .padding(.horizontal, 9).frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture { app.copilot.toggle(tool: call.id) }
            if call.expanded {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(call.input).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.cText2).textSelection(.enabled)
                    if let r = call.result {
                        Text(String(r.prefix(3000))).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(call.isError ? Color.cRed : Color.cText3)
                            .textSelection(.enabled).lineLimit(30)
                    }
                }
                .padding(9)
            }
        }
        .background(Color.cField, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.cHairline))
    }

    private var icon: String {
        switch call.label {
        case "find", "count": return "magnifyingglass"
        case "aggregate": return "line.3.horizontal.decrease"
        case "collection schema": return "chart.bar.xaxis"
        case "list indexes": return "bolt.horizontal"
        case "explain": return "gauge.with.dots.needle.33percent"
        default: return "cylinder.split.1x2"
        }
    }

    private var summary: String {
        let lines = call.input.split(separator: "\n").map(String.init)
        let ns = [lines.first { $0.hasPrefix("db:") }, lines.first { $0.hasPrefix("collection:") }].compactMap { $0?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) }.joined(separator: ".")
        let q = lines.first { $0.hasPrefix("filter:") || $0.hasPrefix("pipeline:") }?.split(separator: ":", maxSplits: 1).last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return [ns, q].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct ProposalCard: View {
    @Environment(AppState.self) private var app
    let p: Proposal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: p.kind == "aggregate" ? "line.3.horizontal.decrease" : "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.cAI)
                Text(p.title).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text("\(p.db).\(p.collection)").font(.system(size: 10.5)).foregroundStyle(Color.cText3)
            }
            Text(code).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.cText2).lineLimit(10)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cField, in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button { app.copy(code) } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 11.5)) }.buttonStyle(.borderless)
                Spacer()
                Button { app.copilot.apply(p) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: p.applied ? "checkmark" : "arrow.down.left").font(.system(size: 10, weight: .bold))
                        Text(p.applied ? "Applied" : (p.kind == "aggregate" ? "Open in pipeline" : "Apply to query bar")).font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 10).frame(height: 24)
                    .background(p.applied ? Color.cText3 : Color.cAI, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Color.cAI.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.cAI.opacity(0.3)))
    }

    private var code: String {
        if p.kind == "aggregate" {
            if let v = try? ShellParser.parse(p.pipeline) { return BFormat.text(v) }
            return p.pipeline
        }
        var parts = ["filter: " + (p.filter.isEmpty ? "{}" : p.filter)]
        if !p.sort.isEmpty { parts.append("sort: " + p.sort) }
        if !p.projection.isEmpty { parts.append("project: " + p.projection) }
        return parts.joined(separator: "\n")
    }
}
