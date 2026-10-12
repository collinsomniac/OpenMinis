import pathlib

# ── 1. Full precision means "no quantization" (nil), not 16 bits. ──
p = pathlib.Path('Providers/LocalMLX/LocalModelHost.swift')
t = p.read_text()

t = t.replace("""    /// 16 = full precision (MLX treats nil/16 as uncompressed).
    var bits: Int {
        switch self {
        case .full: return 16
        case .eightBit: return 8
        case .fourBit: return 4
        }
    }""",
"""    /// Bits for MLX, where **nil means no quantization at all** (`GenerateParameters.kvBits` is `Int?`,
    /// documented "nil = no quantization"). This used to return 16 for full precision, which is not one of
    /// the widths MLX plans for — the affine plan failed to build, `maybeAffineQuantizeKVCache` silently
    /// left the cache uncompressed via `try?`, and "Full precision" did nothing except leave the UI looking
    /// as if the setting had not been applied.
    var bits: Int? {
        switch self {
        case .full: return nil
        case .eightBit: return 8
        case .fourBit: return 4
        }
    }

    /// The width to reason about in the UI and in memory estimates, where "full" is 16 bits wide.
    var displayBits: Int { bits ?? 16 }""")

t = t.replace("""        let kv = LocalKVCachePreference.current
        params.kvBits = kv.bits
        params.kvGroupSize = 64
        params.quantizedKVStart = kv.startTokens""",
"""        let kv = LocalKVCachePreference.current
        // Only ask for a quantised cache when one was actually chosen: passing a width for "full" makes
        // MLX build a plan it cannot apply, and the failure is swallowed.
        if let bits = kv.bits {
            params.kvBits = bits
            params.kvGroupSize = 64
            params.quantizedKVStart = kv.startTokens
        }""")

t = t.replace("""        stats.kvBits = kv.bits
        stats.reuseNote = reuseNote""",
"""        stats.kvBits = kv.displayBits
        stats.reuseNote = reuseNote""")

# ── 2. A per-turn log the phone can hand back over the tunnel. ──
t = t.replace("""/// One turn of the transcript, carrying any images the model must actually see.""",
"""/// A deliberately plain, append-only record of what each turn actually sent.
///
/// [T-nabla-local-mlx-turn-log] The questions that matter here cannot be answered from a screenshot: is the
/// system prompt identical between turns, and if not, where does it first differ? Does the history the app
/// sends have the shape we assume? `reuseNote` names the *decision*; this names the *input* it was made
/// from, and it is readable over the tunnel with `tools/container_ls.py` without the app being touched.
enum LocalTurnLog {
    private static let lock = NSLock()
    private static var lastSystem: String?
    private static var lastHistory: [(role: String, text: String)] = []
    private static let directory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("looplab", isDirectory: true)
    }()
    private static let file = directory.appendingPathComponent("turns.jsonl")

    /// Characters shared with the previous string, which is the only number that matters for prefix reuse.
    private static func commonPrefix(_ a: String, _ b: String) -> Int {
        var n = 0
        for (x, y) in zip(a, b) {
            if x != y { break }
            n += 1
        }
        return n
    }

    private static func head(_ s: String, _ n: Int = 120) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }

    static func note(_ what: String) {
        append(["t": ISO8601DateFormatter().string(from: Date()), "event": what])
    }

    static func turn(model: String, thinking: Bool, kv: String, system: String?,
                     history: [LocalTurn], note: String, promptTokens: Int, reusedTokens: Int,
                     prefillMs: Int, decodeMs: Int, generated: Int) {
        let sys = system ?? ""
        var entry: [String: Any] = [
            "t": ISO8601DateFormatter().string(from: Date()),
            "model": model, "thinking": thinking, "kv": kv,
            "note": note,
            "prompt": promptTokens, "reused": reusedTokens,
            "prefillMs": prefillMs, "decodeMs": decodeMs, "generated": generated,
        ]
        if !sys.isEmpty {
            var s: [String: Any] = [
                "chars": sys.count,
                "head": head(sys),
                "tail": sys.count > 160 ? String(sys.suffix(160)) : "",
            ]
            if let last = lastSystem {
                s["commonPrefixWithPrev"] = commonPrefix(sys, last)
                s["changed"] = last != sys
            }
            entry["system"] = s
        }
        entry["history"] = history.enumerated().map { i, h -> [String: Any] in
            var d: [String: Any] = ["i": i, "role": h.role, "chars": h.text.count, "head": head(h.text, 80)]
            if h.images.count > 0 { d["images"] = h.images.count }
            if !h.toolCalls.isEmpty { d["toolCalls"] = h.toolCalls.count }
            if i < lastHistory.count {
                let was = lastHistory[i]
                d["prevRole"] = was.role
                d["prevChars"] = was.text.count
                d["commonPrefixWithPrev"] = commonPrefix(h.text, was.text)
                d["sameAsPrev"] = (was.role == h.role && was.text == h.text)
            }
            return d
        }
        entry["historyCount"] = history.count
        entry["prevHistoryCount"] = lastHistory.count
        lastSystem = sys
        lastHistory = history.map { ($0.role, $0.text) }
        append(entry)
    }

    private static func append(_ entry: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Bounded: the log is a diagnostic, not a history. One rotation is enough to see a session.
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            if (size ?? 0) > 1_500_000 {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("turns.1.jsonl"))
                try? FileManager.default.moveItem(at: file,
                                                  to: directory.appendingPathComponent("turns.1.jsonl"))
            }
            let data = try JSONSerialization.data(withJSONObject: entry)
            if FileManager.default.fileExists(atPath: file.path),
               let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data + Data("\\n".utf8))
            } else {
                try (data + Data("\\n".utf8)).write(to: file)
            }
        } catch {
            // A diagnostic must never break a turn.
        }
    }
}

/// One turn of the transcript, carrying any images the model must actually see.""")

# Record the turn once the stats are known.
t = t.replace("""        await publishStats(stats)
        onEvent(.done(maxTokensHit: false))""",
"""        await publishStats(stats)
        LocalTurnLog.turn(
            model: id, thinking: thinking,
            kv: "\\(kv.displayBits)|\\(kv.startTokens)",
            system: system, history: history, note: reuseNote,
            promptTokens: stats.promptTokens, reusedTokens: stats.reusedTokens,
            prefillMs: Int(stats.prefillSeconds * 1000), decodeMs: Int(stats.decodeSeconds * 1000),
            generated: stats.generatedTokens)
        onEvent(.done(maxTokensHit: false))""")

# Record benchmark failures too: "it just reset as if I never pressed it" needs a trace.
t = t.replace("""    func benchmark(_ id: String, contextTokens: Int = 0, maxTokens: Int = 128) async throws -> LocalGenStats {""",
"""    func benchmark(_ id: String, contextTokens: Int = 0, maxTokens: Int = 128) async throws -> LocalGenStats {
        LocalTurnLog.note("benchmark start \\(id) ctx=\\(contextTokens) kv=\\(LocalKVCachePreference.current.displayBits)")""")
p.write_text(t)
print("host:", t.count('{') - t.count('}'), "| bits optional:", 'var bits: Int?' in t)

# ── 3. The KV row describes the setting in effect, not the previous turn. ──
p2 = pathlib.Path('Views/Settings/LocalInferenceSettingsView.swift')
t2 = p2.read_text()
old = """            if let s = model.stats, s.kvBytesPerToken > 0 {
                LabeledContent(AppLocalized("K/V per context token")) {
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(Double(s.kvBytesPerToken) * Double(s.kvBits) / 16.0),
                        countStyle: .memory))
                        .font(.callout.monospaced())
                }
            }"""
new = """            // Describe what is selected *now*. This row used to read the previous turn's stats, so it
            // showed the old setting's numbers until another turn had run — which made a sweep unreadable.
            if let perToken = model.kvBytesPerTokenForSelection, perToken > 0 {
                LabeledContent(AppLocalized("K/V per context token")) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(perToken), countStyle: .memory))
                        .font(.callout.monospaced())
                }
                let context = max(model.stats?.contextTokens ?? 8192, 1)
                LabeledContent(AppLocalized("Read per generated token")) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(perToken * Double(context)), countStyle: .memory))
                            .font(.callout.monospaced())
                        Text("\\(AppLocalized("K/V at")) \\(context) tok · + \\(AppLocalized("weights on every token"))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }"""
assert old in t2
t2 = t2.replace(old, new)

# The accessor it needs.
t2 = t2.replace("""    func measure(_ id: String, contextTokens: Int = 0) {
        guard !benching else { return }""",
"""    /// K/V bytes per context token for the *currently selected* precision, taken from whichever model is
    /// resident (or the first in the library). Independent of whether a turn has run yet.
    var kvBytesPerTokenForSelection: Double? {
        let id = engine.residentModelId
        guard let info = (id.flatMap { want in models.first { $0.id == want } }) ?? models.first,
              info.kvBytesPerToken > 0 else { return nil }
        let bits = Double(kvPrecision.bits ?? 16)
        return Double(info.kvBytesPerToken) * bits / 16.0
    }

    func measure(_ id: String, contextTokens: Int = 0) {
        guard !benching else { return }""")

# Persist the benchmark so the row survives a relaunch (it was memory-only, so it kept disappearing).
t2 = t2.replace("""    @Published var benchResult: LocalGenStats?""",
"""    @Published var benchResult: LocalGenStats? {
        didSet { Self.persistBench(benchResult, "nabla.localInference.bench") }
    }""")
t2 = t2.replace("""    @Published var benchContextResult: LocalGenStats?""",
"""    @Published var benchContextResult: LocalGenStats? {
        didSet { Self.persistBench(benchContextResult, "nabla.localInference.benchContext") }
    }

    /// Benchmark results are a measurement of the device, not of this launch: keep them so the Performance
    /// section still shows the ceiling after the app is restarted.
    private static func persistBench(_ s: LocalGenStats?, _ key: String) {
        guard let s, let d = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }

    private static func loadBench(_ key: String) -> LocalGenStats? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LocalGenStats.self, from: d)
    }""")
p2.write_text(t2)
print("settings:", t2.count('{') - t2.count('}'))

# LocalGenStats must be Codable to persist.
t = p.read_text()
t = t.replace("struct LocalGenStats: Sendable {", "struct LocalGenStats: Sendable, Codable {")
p.write_text(t)
print("stats codable:", "Codable" in t.split("struct LocalGenStats")[1][:40])
