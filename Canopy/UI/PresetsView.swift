import SwiftUI

/// The query bar's preset button: a popover of one-click filters and sorts
/// built from the fields seen in this collection.
struct PresetsButton: View {
    @Bindable var m: DocumentsModel
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12, weight: .medium))
                .foregroundStyle(open ? Color.cAccent : Color.cText2)
                .frame(width: 30, height: 30)
                .background(Color.cPill.opacity(hover || open ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help("Preset filters and sorts")
        .popover(isPresented: $open, arrowEdge: .bottom) { PresetsPanel(m: m) { open = false } }
    }
}

struct PresetsPanel: View {
    @Bindable var m: DocumentsModel
    var dismiss: () -> Void = {}
    var maxHeight: CGFloat = 440
    @State private var missing = false

    private var c: FieldCatalog { m.catalog }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Color.cHairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sortSection
                    timeSection
                    valueSection
                    presenceSection
                    if c.isEmpty {
                        Label("Run a query to get presets for this collection's fields.", systemImage: "sparkle.magnifyingglass")
                            .font(.system(size: 11.5)).foregroundStyle(Color.cText3)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Color.cHairline).frame(height: 1)
            footer
        }
        .frame(width: 440)
        .background(Color.cPanel)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill").font(.system(size: 15)).foregroundStyle(Color.cAccent)
            Text("Presets").font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(m.collection).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.cText3)
                .padding(.horizontal, 7).padding(.vertical, 3).background(Color.cPill, in: Capsule())
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var sortSection: some View {
        section("Sort", icon: "arrow.up.arrow.down") {
            Flow(spacing: 6) {
                ForEach(QueryPresets.sorts(c)) { p in
                    Chip(text: p.title, icon: p.icon, active: same(m.sortText, p.sort)) { apply(p) }
                }
            }
        }
    }

    @ViewBuilder private var timeSection: some View {
        let recent = QueryPresets.recent(c)
        if let field = recent.first?.window?.field {
            section("Time window", icon: "clock", trailing: field) {
                HStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { i, p in
                        Button { apply(p) } label: {
                            Text(p.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.cText)
                                .frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(SegmentStyle())
                        if i < recent.count - 1 { Rectangle().fill(Color.cHairline).frame(width: 1, height: 16) }
                    }
                }
                .background(Color.cField, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.cHairline))
            }
        }
    }

    @ViewBuilder private var valueSection: some View {
        let groups = QueryPresets.values(c)
        if !groups.isEmpty {
            section("Match a value", icon: "equal.circle") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.field) { g in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(g.field).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.cText2)
                                .lineLimit(1).truncationMode(.middle).frame(width: 104, alignment: .leading)
                                .help(g.field)
                            Flow(spacing: 5) {
                                ForEach(g.presets.prefix(8)) { p in
                                    Chip(text: unquoted(p.title), mono: true, tint: valueTint(p.title), active: same(m.filterText, p.filter)) { apply(p) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var presenceSection: some View {
        let fields = c.paths.filter { $0 != "_id" && !$0.contains(".") }.prefix(16)
        if !fields.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "checklist").font(.system(size: 10, weight: .semibold))
                    Text("FIELD PRESENCE").font(.system(size: 10, weight: .semibold)).tracking(0.6)
                    Spacer()
                    MiniToggle(options: ["Has", "Missing"], selection: Binding(get: { missing ? 1 : 0 }, set: { missing = $0 == 1 }))
                }
                .foregroundStyle(Color.cText3)
                Flow(spacing: 5) {
                    ForEach(Array(fields), id: \.self) { f in
                        let p = QueryPreset(title: f, icon: "", filter: "{ \(QueryPresets.key(f)): { $exists: \(!missing) } }")
                        Chip(text: f, icon: missing ? "circle.dashed" : "checkmark.circle", mono: true, active: same(m.filterText, p.filter)) { apply(p) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Applies and runs right away").font(.system(size: 11)).foregroundStyle(Color.cText3)
            Spacer()
            Button {
                m.filterText = ""; m.sortText = ""
                Task { await m.run() }
            } label: {
                Label("Clear filter & sort", systemImage: "xmark.circle").font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Color.cText2)
            .disabled(m.filterText.isEmpty && m.sortText.isEmpty)
            .opacity(m.filterText.isEmpty && m.sortText.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, icon: String, trailing: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                if let trailing {
                    Text("·")
                    Text(trailing).font(.system(size: 10.5, design: .monospaced)).textCase(nil)
                }
            }
            .foregroundStyle(Color.cText3)
            content()
        }
    }

    private func apply(_ p: QueryPreset) {
        Task { await m.applyPreset(p) }
        dismiss()
    }

    private func same(_ text: String, _ preset: String?) -> Bool {
        guard let preset, !text.isEmpty else { return false }
        return text.filter { !$0.isWhitespace } == preset.filter { !$0.isWhitespace }
    }

    private func unquoted(_ literal: String) -> String {
        literal.count >= 2 && literal.hasPrefix("\"") && literal.hasSuffix("\"") ? String(literal.dropFirst().dropLast()) : literal
    }

    private func valueTint(_ literal: String) -> Color {
        if literal.hasPrefix("\"") { return Color(nsColor: Theme.synString) }
        if literal == "true" || literal == "false" || literal == "null" { return Color(nsColor: Theme.synKeyword) }
        return Color(nsColor: Theme.synNumber)
    }
}

// MARK: - Pieces

private struct Chip: View {
    var text: String
    var icon: String? = nil
    var mono = false
    var tint: Color = .cText
    var active = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon, !icon.isEmpty {
                    Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(active ? Color.cAccent : Color.cText3)
                }
                Text(text).font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.cAccent : tint).lineLimit(1)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(active ? Color.cAccent.opacity(0.14) : (hover ? Color.cPill : Color.cField),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(active ? Color.cAccent.opacity(0.5) : Color.cHairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// A compact two-way switch in the app's own style (no system blue).
private struct MiniToggle: View {
    var options: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, title in
                Button { withAnimation(.snappy(duration: 0.15)) { selection = i } } label: {
                    Text(title).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selection == i ? Color.cText : Color.cText3)
                        .padding(.horizontal, 9).frame(height: 20)
                        .background {
                            if selection == i {
                                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.cRaised)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.cPill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct SegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hover(pressed: configuration.isPressed) { configuration.label }
    }

    private struct Hover<L: View>: View {
        var pressed: Bool
        @ViewBuilder var label: () -> L
        @State private var hover = false
        var body: some View {
            label()
                .background((pressed ? Color.cAccent.opacity(0.18) : hover ? Color.cPill : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(2)
                .onHover { hover = $0 }
        }
    }
}

/// Left-to-right wrapping layout for chips.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let w = rows.map { $0.width }.max() ?? 0
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + s.width > maxWidth { rows.append(Row()) }
            var r = rows[rows.count - 1]
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
