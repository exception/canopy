import Foundation

/// Runs Claude through the user's Claude Code install (`claude -p`), so the
/// AI features work with their existing login and no API key. Canopy's tools
/// reach Claude through a local MCP server (see ToolServer).
enum ClaudeCLI {
    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static var model: String { UserDefaults.standard.string(forKey: "aiModel") ?? "opus" }
    static var quickModel: String { UserDefaults.standard.string(forKey: "aiQuickModel") ?? "sonnet" }

    private static var cachedPath: String?

    static func executable() -> String? {
        if let cachedPath { return cachedPath }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [UserDefaults.standard.string(forKey: "claudePath") ?? "", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                          "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let p = candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }) { cachedPath = p; return p }
        // Ask a login shell, which has the user's PATH.
        let pr = Process()
        pr.executableURL = URL(fileURLWithPath: "/bin/zsh")
        pr.arguments = ["-lc", "command -v claude"]
        let out = Pipe(); pr.standardOutput = out; pr.standardError = Pipe()
        try? pr.run(); pr.waitUntilExit()
        let p = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !p.isEmpty, FileManager.default.isExecutableFile(atPath: p) { cachedPath = p; return p }
        return nil
    }

    static var isAvailable: Bool { executable() != nil }

    static var workDir: URL {
        let u = Storage.dir.appendingPathComponent("claude")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Never let a spawned agent report into a terminal multiplexer we were launched from.
        for k in env.keys where k.hasPrefix("PITWALL_") { env.removeValue(forKey: k) }
        env["CLAUDE_CODE_ENTRYPOINT"] = "canopy"
        return env
    }

    private static func baseArgs(system: String, model: String) -> [String] {
        ["-p", "--model", model, "--system-prompt", system, "--setting-sources", "", "--disable-slash-commands"]
    }

    /// One-shot call that returns JSON matching `schema`.
    static func structured(prompt: String, system: String, schema: [String: Any], model: String = quickModel) async throws -> [String: Any] {
        guard let exe = executable() else { throw Failure(message: "Claude Code isn't installed. Install it from claude.com/code, or set its path in Settings.") }
        let schemaJSON = String(data: try JSONSerialization.data(withJSONObject: schema), encoding: .utf8)!
        var args = baseArgs(system: system, model: model)
        args += ["--output-format", "json", "--tools", "", "--no-session-persistence", "--json-schema", schemaJSON, "--", prompt]
        let data = try await run(exe, args)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(message: "Claude returned something unexpected: \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
        }
        if obj["is_error"] as? Bool == true { throw Failure(message: (obj["result"] as? String) ?? "Claude failed") }
        if let s = obj["structured_output"] as? [String: Any] { return s }
        if let r = obj["result"] as? String, let d = r.data(using: .utf8), let s = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return s }
        throw Failure(message: "Claude didn't return structured output")
    }

    private static func run(_ exe: String, _ args: [String]) async throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment()
        p.currentDirectoryURL = workDir
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        return try await withCheckedThrowingContinuation { cont in
            // Both pipes are drained to EOF on their own queues, so neither can fill up and stall the child.
            DispatchQueue.global().async {
                let errBox = ErrBox()
                let g = DispatchGroup()
                g.enter()
                DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                g.wait()
                if p.terminationStatus != 0 && data.isEmpty {
                    let e = String(data: errBox.data, encoding: .utf8) ?? ""
                    cont.resume(throwing: Failure(message: e.isEmpty ? "claude exited with \(p.terminationStatus)" : String(e.suffix(600))))
                } else { cont.resume(returning: data) }
            }
        }
    }

    private final class ErrBox: @unchecked Sendable { var data = Data() }

    // MARK: Streaming agent

    enum Event {
        case session(String)
        case textDelta(String)
        case text(String)               // a complete assistant text block
        case toolUse(id: String, name: String, input: [String: Any])
        case toolResult(id: String, text: String, isError: Bool)
        case done(cost: Double?, error: String?)
    }

    final class Handle {
        fileprivate var process: Process?
        func cancel() { process?.terminate() }
    }

    /// Streams an agent turn. `mcpURL` is Canopy's tool server.
    static func stream(prompt: String, system: String, resume: String?, mcpURL: String, handle: Handle, model: String = model) -> AsyncStream<Event> {
        AsyncStream { cont in
            guard let exe = executable() else {
                cont.yield(.done(cost: nil, error: "Claude Code isn't installed. Install it from claude.com/code, or set its path in Settings."))
                cont.finish()
                return
            }
            let mcp = "{\"mcpServers\":{\"canopy\":{\"type\":\"http\",\"url\":\"\(mcpURL)\"}}}"
            var args = baseArgs(system: system, model: model)
            args += ["--output-format", "stream-json", "--verbose", "--include-partial-messages",
                     "--tools", "", "--mcp-config", mcp, "--strict-mcp-config", "--allowedTools", "mcp__canopy"]
            if let resume { args += ["--resume", resume] }
            args += ["--", prompt]
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            p.environment = environment()
            p.currentDirectoryURL = workDir
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            p.standardInput = FileHandle.nullDevice
            handle.process = p
            var pending = Data()
            var finished = false
            func handleLine(_ line: Data) {
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let type = o["type"] as? String else { return }
                switch type {
                case "system":
                    if let sid = o["session_id"] as? String { cont.yield(.session(sid)) }
                case "stream_event":
                    if let ev = o["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                       let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta", let t = delta["text"] as? String {
                        cont.yield(.textDelta(t))
                    }
                case "assistant":
                    let content = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                    for b in content {
                        if b["type"] as? String == "text", let t = b["text"] as? String { cont.yield(.text(t)) }
                        if b["type"] as? String == "tool_use" {
                            cont.yield(.toolUse(id: b["id"] as? String ?? "", name: b["name"] as? String ?? "", input: b["input"] as? [String: Any] ?? [:]))
                        }
                    }
                case "user":
                    let content = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                    for b in content where b["type"] as? String == "tool_result" {
                        var text = ""
                        if let s = b["content"] as? String { text = s }
                        else if let arr = b["content"] as? [[String: Any]] { text = arr.compactMap { $0["text"] as? String }.joined(separator: "\n") }
                        cont.yield(.toolResult(id: b["tool_use_id"] as? String ?? "", text: text, isError: b["is_error"] as? Bool ?? false))
                    }
                case "result":
                    finished = true
                    let isErr = o["is_error"] as? Bool ?? false
                    cont.yield(.done(cost: o["total_cost_usd"] as? Double, error: isErr ? (o["result"] as? String ?? "Claude failed") : nil))
                default: break
                }
            }
            cont.onTermination = { _ in if p.isRunning { p.terminate() } }
            do { try p.run() } catch {
                cont.yield(.done(cost: nil, error: error.localizedDescription))
                cont.finish()
                return
            }
            // One reader thread owns `pending`/`finished`: read stdout to EOF, then reap the process.
            DispatchQueue.global().async {
                let errBox = ErrBox()
                let g = DispatchGroup()
                g.enter()
                DispatchQueue.global().async { errBox.data = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                let fh = out.fileHandleForReading
                while true {
                    let d = fh.availableData
                    if d.isEmpty { break }
                    pending.append(d)
                    while let nl = pending.firstIndex(of: 10) {
                        let line = pending[pending.startIndex..<nl]
                        pending.removeSubrange(pending.startIndex...nl)
                        handleLine(Data(line))
                    }
                }
                if !pending.isEmpty { handleLine(pending) }
                p.waitUntilExit()
                g.wait()
                if !finished {
                    let e = String(data: errBox.data, encoding: .utf8) ?? ""
                    cont.yield(.done(cost: nil, error: p.terminationReason == .uncaughtSignal ? nil : (e.isEmpty ? "claude exited with \(p.terminationStatus)" : String(e.suffix(600)))))
                }
                cont.finish()
            }
        }
    }
}
/// Prompts shared by the one-shot AI features.
enum AIPrompts {
    static func today() -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date())
    }

    /// Pins the language of prose fields. Without it the model sometimes answers in the language of the sampled data.
    static var language: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "en" } ?? "en"
        let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
        return "Write all prose (notes, reasons, explanations) in the language the user wrote their request in; when there is no request, write in \(name). " +
            "Never switch language because of the language of field names or values in the data."
    }

    static let syntax = """
    Write MongoDB values in mongosh syntax: unquoted keys are fine, use ObjectId("…"), ISODate("…"), Decimal128("…"), Long("…"), /regex/i. \
    Use field names exactly as they appear in the schema, including dotted paths for nested fields. Decimal128 fields compare correctly against plain numbers.
    """

    static func queryRequest(ns: String, schema: String, current: String, request: String) -> String {
        """
        Collection: \(ns)
        Current time: \(today())

        Schema (from a sample):
        \(schema)

        Current query: \(current)

        Request: \(request)
        """
    }
}
