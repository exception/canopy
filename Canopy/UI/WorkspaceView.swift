import SwiftUI

struct WorkspaceView: View {
    @Environment(AppState.self) private var app
    @Bindable var tab: WorkspaceTab

    var body: some View {
        if tab.kind == .server {
            ServerView(session: app.session!)
        } else {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Color.cHairline).frame(height: 1)
                Group {
                    switch tab.mode {
                    case .documents: DocumentsView(m: tab.docs)
                    case .aggregations: AggregationView(m: tab.agg)
                    case .schema: SchemaView(m: tab.schema, tab: tab)
                    case .indexes: IndexesView(m: tab.indexes)
                    case .explain: ExplainView(m: tab.explain, tab: tab)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        let st = app.session?.stat(tab.db, tab.collection)
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tab.db).foregroundStyle(Color.cText3)
                    Text("/").foregroundStyle(Color.cText3)
                    Text(tab.collection).fontWeight(.semibold)
                }
                .font(.system(size: 15))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Stat(label: "documents", value: Fmt.count(st?.count))
                        Stat(label: "data", value: Fmt.bytes(st?.size))
                        Stat(label: "avg", value: Fmt.bytes(st?.avgObjSize))
                        Stat(label: "indexes", value: st?.indexCount.map(String.init) ?? "—")
                        Stat(label: "index size", value: Fmt.bytes(st?.totalIndexSize))
                    }
                    HStack(spacing: 12) {
                        Stat(label: "docs", value: Fmt.compact(st?.count))
                        Stat(label: "data", value: Fmt.bytes(st?.size))
                    }
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                ModePicker(mode: $tab.mode)
                ModePicker(mode: $tab.mode, compact: true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(Color.cPanel)
    }
}

struct Stat: View {
    var label: String
    var value: String
    var body: some View {
        HStack(spacing: 4) {
            Text(value).font(.system(size: 11.5, weight: .semibold).monospacedDigit()).foregroundStyle(Color.cText2)
            Text(label).font(.system(size: 11.5)).foregroundStyle(Color.cText3)
        }
        .fixedSize()
    }
}

struct ModePicker: View {
    @Binding var mode: WorkspaceMode
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(WorkspaceMode.allCases) { m in
                Button { withAnimation(.snappy(duration: 0.2)) { mode = m } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.icon).font(.system(size: 11))
                        if !compact || mode == m { Text(m.rawValue).font(.system(size: 12, weight: mode == m ? .semibold : .regular)) }
                    }
                    .foregroundStyle(mode == m ? Color.cText : Color.cText2)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background {
                        if mode == m {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.cRaised)
                                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "sel", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(m.rawValue)
            }
        }
        .fixedSize()
        .padding(2)
        .background(Color.cPill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// A capsule button used across the app.
struct PillButton: View {
    var title: String
    var icon: String? = nil
    var tint: Color = .cText2
    var prominent = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)) }
                if !title.isEmpty { Text(title).font(.system(size: 12, weight: .medium)) }
            }
            .foregroundStyle(prominent ? Color.white : tint)
            .padding(.horizontal, title.isEmpty ? 7 : 10).frame(height: 26)
            .background(prominent ? Color.cAccent.opacity(hover ? 0.9 : 1) : (hover ? Color.cPill : Color.cPill.opacity(0.6)), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The "ask Claude" input used by Documents and Aggregations.
struct AskBar: View {
    @Binding var text: String
    var placeholder: String
    var busy: Bool
    var note: String?
    var error: String?
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 13, weight: .medium)).foregroundStyle(Color.cAI)
                    .symbolEffect(.pulse, isActive: busy)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .disabled(busy)
                if busy {
                    Text("Claude is writing a query…").font(.system(size: 11.5)).foregroundStyle(Color.cText3)
                    ProgressView().controlSize(.small)
                } else if !text.isEmpty {
                    Text("↩").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cText3)
                } else {
                    Text("⌘L").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Color.cText3)
                }
            }
            .padding(.horizontal, 11).frame(height: 34)
            .background(Color.cAI.opacity(focused ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.cAI.opacity(focused ? 0.45 : 0.18)))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(Color.cRed).lineLimit(3).textSelection(.enabled)
            } else if let note {
                Label(note, systemImage: "sparkle").font(.system(size: 11.5)).foregroundStyle(Color.cText2).lineLimit(2)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusAsk)) { _ in focused = true }
    }
}

/// List / Table / JSON switch: a raised thumb that slides between icons, and the picked
/// icon gives a small bounce. The label of the picked mode slides out next to its icon.
struct ViewModeSwitch: View {
    @Binding var selection: DocViewMode
    @Namespace private var ns
    @State private var hovered: DocViewMode?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(DocViewMode.allCases) { v in
                let on = selection == v
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { selection = v }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: v.icon)
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .symbolEffect(.bounce.down, value: on)
                        if on {
                            Text(v.rawValue).font(.system(size: 11.5, weight: .semibold))
                                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .leading)), removal: .opacity))
                        }
                    }
                    .foregroundStyle(on ? Color.cAccent : hovered == v ? Color.cText : Color.cText2)
                    .padding(.horizontal, on ? 10 : 8).frame(height: 26)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.cRaised)
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.cAccent.opacity(0.35), lineWidth: 0.75))
                                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? v : (hovered == v ? nil : hovered) }
                .help("\(v.rawValue) view")
            }
        }
        .padding(2)
        .background(Color.cPill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .fixedSize()
    }
}
