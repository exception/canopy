import Charts
import SwiftUI

struct OpsPoint: Identifiable {
    var id = UUID()
    var at: Date
    var kind: String
    var rate: Double
}

@MainActor @Observable
final class ServerMonitor {
    let session: Session
    var status: ServerStatus?
    var points: [OpsPoint] = []
    var ops: [BDoc] = []
    var error: String?
    private var last: ServerStatus?
    private var task: Task<Void, Never>?

    init(session: Session) { self.session = session }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    private func tick() async {
        do {
            let s = try await session.service.serverStatus()
            if let l = last {
                let dt = max(s.at.timeIntervalSince(l.at), 0.1)
                for k in ["query", "insert", "update", "delete", "getmore", "command"] {
                    points.append(OpsPoint(at: s.at, kind: k, rate: max(0, ((s.opcounters[k] ?? 0) - (l.opcounters[k] ?? 0)) / dt)))
                }
                let cutoff = Date().addingTimeInterval(-90)
                points.removeAll { $0.at < cutoff }
            }
            last = s
            status = s
            ops = (try? await session.service.currentOps().filter {
                $0["op"]?.stringValue != "none" && $0["desc"]?.stringValue?.hasPrefix("conn") == true && $0["command"]?.doc?["currentOp"] == nil
            }) ?? []
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ServerView: View {
    let session: Session
    @State private var monitor: ServerMonitor?

    var body: some View {
        ScrollView {
            if let mon = monitor {
                VStack(alignment: .leading, spacing: 16) {
                    header(mon)
                    if let s = mon.status {
                        HStack(spacing: 10) {
                            Metric(title: "Version", value: s.version)
                            Metric(title: "Uptime", value: Fmt.duration(s.uptime))
                            Metric(title: "Connections", value: "\(s.connections)")
                            Metric(title: "Memory", value: "\(Int(s.residentMB)) MB")
                            Metric(title: "Network in / out", value: "\(Fmt.bytes(s.bytesIn)) / \(Fmt.bytes(s.bytesOut))")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Operations per second").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("last 90 s · live").font(.system(size: 11)).foregroundStyle(Color.cText3)
                        }
                        Chart(mon.points) { p in
                            LineMark(x: .value("t", p.at), y: .value("ops/s", p.rate))
                                .foregroundStyle(by: .value("op", p.kind))
                                .interpolationMethod(.monotone)
                        }
                        .chartForegroundStyleScale(["query": Color.cAccent, "insert": Color(ns: Theme.blue), "update": Color.cAmber,
                                                    "delete": Color.cRed, "getmore": Color(ns: Theme.violet), "command": Color.cText3])
                        .frame(height: 200)
                    }
                    .padding(14).card(10)
                    HStack(alignment: .top, spacing: 14) {
                        dbSizes.frame(maxWidth: .infinity)
                        currentOps(mon).frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
        }
        .background(Color(ns: Theme.window))
        .onAppear {
            if monitor == nil { monitor = ServerMonitor(session: session) }
            monitor?.start()
        }
        .onDisappear { monitor?.stop() }
    }

    private func header(_ mon: ServerMonitor) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack").font(.system(size: 20)).foregroundStyle(Color.cAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.saved.name).font(.system(size: 17, weight: .semibold))
                Text([mon.status?.host, mon.status?.replicaSet.map { "replica set \($0)" }, mon.status?.storageEngine].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(Color.cText3)
            }
            Spacer()
            if let e = mon.error { Text(e).font(.system(size: 11)).foregroundStyle(Color.cRed) }
        }
    }

    private var dbSizes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Databases").font(.system(size: 13, weight: .semibold))
            let dbs = session.databases.filter { $0.sizeOnDisk > 0 }.sorted { $0.sizeOnDisk > $1.sizeOnDisk }
            let maxSize = dbs.first?.sizeOnDisk ?? 1
            ForEach(dbs) { d in
                HStack(spacing: 10) {
                    Text(d.name).font(.system(size: 12, design: .monospaced)).frame(width: 90, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3).fill(Color.cAccent.gradient).frame(width: max(3, g.size.width * d.sizeOnDisk / maxSize))
                    }.frame(height: 10)
                    Text(Fmt.bytes(d.sizeOnDisk)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.cText3).frame(width: 64, alignment: .trailing)
                }
            }
        }
        .padding(14).card(10)
    }

    private func currentOps(_ mon: ServerMonitor) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Current operations").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(mon.ops.count) active").font(.system(size: 11)).foregroundStyle(Color.cText3)
            }
            if mon.ops.isEmpty {
                Text("Nothing running right now.").font(.system(size: 12)).foregroundStyle(Color.cText3).padding(.vertical, 8)
            }
            ForEach(Array(mon.ops.prefix(12).enumerated()), id: \.offset) { _, op in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(op["op"]?.stringValue ?? "?") \(op["ns"]?.stringValue ?? "")").font(.system(size: 12, weight: .medium, design: .monospaced))
                        Text(op["command"].map { BFormat.text($0, pretty: false) } ?? "").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.cText3).lineLimit(1)
                    }
                    Spacer()
                    Text("\(Int(op["secs_running"]?.number ?? 0)) s").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.cText2)
                    if !session.readOnly, let id = op["opid"] {
                        Button("Kill") { Task { try? await session.service.killOp(id) } }.controlSize(.small)
                    }
                }
                Divider()
            }
        }
        .padding(14).card(10)
    }
}
