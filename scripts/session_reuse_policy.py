import pathlib

p = pathlib.Path('Providers/LocalMLX/LocalModelHost.swift')
t = p.read_text()

# ── 1. Stats carry the reason the cache was or was not reused. ──
t = t.replace("""    var kvBytesPerToken: Int = 0
    var kvBits: Int = 16""",
"""    var kvBytesPerToken: Int = 0
    var kvBits: Int = 16
    /// Why this turn did or did not reuse the session's prompt cache. Shown in Performance: "0 reused" has
    /// several very different causes (a new session, a rewritten transcript, a system prompt that changed
    /// above the cached prefix) and they need different fixes, so the decision explains itself.
    var reuseNote: String = \"\"""")
t = t.replace("""    var prefillTokensPerSecond: Double { prefillSeconds > 0 ? Double(promptTokens - reusedTokens) / prefillSeconds : 0 }""",
"""    var prefillTokensPerSecond: Double { prefillSeconds > 0 ? Double(promptTokens - reusedTokens) / prefillSeconds : 0 }
    var cacheHitRatio: Double { promptTokens > 0 ? Double(reusedTokens) / Double(promptTokens) : 0 }""")

# ── 2. The session policy: update in place, rebuild only on real divergence. ──
old_key = """        // [T-nabla-local-mlx-tools] The tool set is part of the prompt (the template renders it), so a
        // session prefilled without tools must not be reused with them, and vice versa.
        let toolKey = (tools ?? []).compactMap { ($0["function"] as? [String: any Sendable])?["name"] as? String }
            .joined(separator: ",")
        let key = "\\(id)|\\(system ?? "")|\\(thinking)|\\(toolKey)"
        if sessionKey != key { session = nil; consumed = [] }"""
new_key = """        // [T-nabla-local-mlx-session-policy] Only the model and the thinking mode force a new session.
        //
        // The system prompt and the tool set are *not* part of this key, because `ChatSession` re-renders
        // its leading messages from its own current `instructions` and `tools` on every call (see
        // `streamDetails`, which reads both when it builds `leadingMessages`), and it then applies its
        // `PromptCacheReusePolicy`: it finds the longest common prefix with the new prompt and
        // `.trimToCommonPrefix` rewinds the KV cache to it, prefilling only the difference.
        //
        // The previous version keyed on the system prompt text and rebuilt the session whenever it changed
        // — which threw away that machinery for a prompt that is rebuilt every turn. With this app's
        // ~11.5k-token agent prompt that is the difference between re-prefilling 11.5k tokens (18 s on
        // device) and prefilling whatever the turn actually added.
        let key = "\\(id)|\\(thinking)"
        if sessionKey != key { session = nil; consumed = [] }"""
assert old_key in t
t = t.replace(old_key, new_key)

# ── 3. Reuse decision, with a reason. ──
old_reuse = """        var continues = false
        if session != nil, sessionKey == key, consumed.count <= prior.count {
            continues = Self.isExtension(of: consumed, by: prior)
        }"""
new_reuse = """        var continues = false
        var reuseNote = "new session"
        if session != nil, sessionKey == key {
            switch Self.compare(consumed: consumed, prior: prior) {
            case .matches:
                continues = true
                reuseNote = "continuing the session (\\(consumed.count) messages cached)"
            case .lastAssistantRewritten:
                // The transcript's copy of the previous answer differs from the text this session
                // generated (a thinking model often keeps the reasoning the app stores without it, and
                // markdown or whitespace can differ). The cache holds the answer that was actually
                // produced, which is the truthful context, so continue rather than re-prefill everything.
                continues = true
                reuseNote = "continuing; the stored copy of the previous reply differs from the text generated"
            case .transcriptShorter:
                reuseNote = "rebuilt: the transcript is shorter than what this session has already generated"
            case .differs(let at, let what):
                reuseNote = "rebuilt: history message \\(at) differs (\\(what))"
            }
        } else if session != nil {
            reuseNote = "rebuilt: model or thinking mode changed"
        }"""
assert old_reuse in t
t = t.replace(old_reuse, new_reuse)

# ── 4. Update instructions/tools in place on the live session. ──
old_live = """        let s: MLXLMCommon.ChatSession
        if continues, let live = session {
            s = live
        } else {"""
new_live = """        let s: MLXLMCommon.ChatSession
        if continues, let live = session {
            // Hand the live session the current prompt and tool set: it re-renders its leading messages
            // from these every call, so this is how a changed system prompt is applied without losing the
            // cache. Leaving them stale would silently answer from the previous turn's instructions.
            live.instructions = system
            live.tools = tools
            s = live
        } else {"""
assert old_live in t
t = t.replace(old_live, new_live)

# ── 5. Publish the reason. ──
t = t.replace("""        stats.kvBytesPerToken = info.kvBytesPerToken
        stats.kvBits = kv.bits""",
"""        stats.kvBytesPerToken = info.kvBytesPerToken
        stats.kvBits = kv.bits
        stats.reuseNote = reuseNote""")

# ── 6. Replace isExtension with a comparison that names the difference. ──
start = t.index("    /// Is `prior` the transcript the session holds, plus more? Split out of the call site because the")
end = t.index("    private static func message(_ t: LocalTurn) -> MLXLMCommon.Chat.Message {")
t = t[:start] + '''    /// How the app's transcript relates to what this session has already consumed.
    enum TranscriptRelation {
        case matches
        /// Everything matches except the final assistant entry — the app's stored copy of the reply.
        case lastAssistantRewritten
        case transcriptShorter
        case differs(at: Int, what: String)
    }

    /// Compare the transcript the app is sending against what this session generated.
    ///
    /// [T-nabla-local-mlx-reuse-guard] This is a **correctness** check, not a speed heuristic: the session
    /// appends new messages to the conversation it holds, so if the app has rewritten an earlier message
    /// the session would answer from a context that no longer matches the transcript on screen. When the
    /// prefix does match, the session is handed only the new turns and its own prompt-cache policy reuses
    /// what it can.
    private static func compare(consumed: [(role: String, text: String, images: Int)],
                                prior: [LocalTurn]) -> TranscriptRelation {
        if prior.count < consumed.count { return .transcriptShorter }
        for (i, was) in consumed.enumerated() {
            let now = prior[i]
            let sameText = was.text.trimmingCharacters(in: .whitespacesAndNewlines)
                == now.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let sameImages = was.images == now.images.count
            if was.role == now.role, sameText, sameImages { continue }
            if i == consumed.count - 1, was.role == "assistant", now.role == "assistant" {
                return .lastAssistantRewritten
            }
            if was.role != now.role { return .differs(at: i, what: "role \\(was.role)→\\(now.role)") }
            if !sameImages { return .differs(at: i, what: "image count") }
            return .differs(at: i, what: "text")
        }
        return .matches
    }

''' + t[end:]

# ── 7. Benchmark at a chosen context length, so the KV lever can be measured where it matters. ──
old_bench = t[t.index("    func benchmark(_ id: String, maxTokens: Int = 128) async throws -> LocalGenStats {"):t.index("    /// Is `prior` the transcript the session holds, plus more?") if False else t.index("    /// How the app's transcript relates to what this session has already consumed.") ]
new_bench = '''    /// Measure the engine with no history, optionally behind a large synthetic prompt.
    ///
    /// A short-prompt benchmark is the engine's ceiling and says nothing about the case the app is
    /// actually in: at ~11.5k tokens of agent prompt, the per-token read is dominated by the KV cache, and
    /// that is the term the KV precision setting exists to change. Measuring both, at the same device
    /// temperature, is what makes the two comparable — and it is the only way to tell whether quantising
    /// K/V helps or hurts, since MLX's quantised attention path dequantises before the matmul.
    func benchmark(_ id: String, contextTokens: Int = 0, maxTokens: Int = 128) async throws -> LocalGenStats {
        var stats = LocalGenStats(model: id)
        var text = "Count from 1 to 40 in words, comma separated."
        if contextTokens > 0 {
            // The engine reports the exact prompt length, so this only has to be approximately right.
            let phrase = "The quick brown fox jumps over the lazy dog beside the river at dawn. "
            let repeats = max(1, (contextTokens * 4) / phrase.count)
            text = String(repeating: phrase, count: repeats)
                + "\\nIgnore the text above. Count from 1 to 40 in words, comma separated."
        }
        let history = [LocalTurn(role: "user", text: text)]
        // A fresh session every time: reusing one would reuse a cache and flatter the number.
        session = nil; sessionKey = nil; consumed = []
        try await stream(modelId: id, system: nil, history: history,
                         maxTokens: maxTokens, temperature: 0, thinking: false) { ev in
            if case .done = ev {}
        }
        let last = await MainActor.run { LocalEngineState.shared.lastStats }
        return last ?? stats
    }

'''
t = t.replace(old_bench, new_bench)

p.write_text(t)
print("host braces:", t.count('{') - t.count('}'))
print("isExtension left:", t.count('isExtension'))
