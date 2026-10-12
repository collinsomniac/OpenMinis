import pathlib

p = pathlib.Path('Providers/LocalMLX/LocalModelHost.swift')
t = p.read_text()

# ─────────────────────────────────────────────────────────────────────────────
# 1. A small pool of live sessions, keyed by design intent — not one per model.
# ─────────────────────────────────────────────────────────────────────────────
t = t.replace("""    private var session: MLXLMCommon.ChatSession?
    private var sessionKey: String?
    /// The transcript the live session has already consumed, *including* the reply it generated.
    private var consumed: [(role: String, text: String, images: Int)] = []""",
"""    /// One live conversation: MLX's session (which owns a KV cache) plus what it has already consumed.
    private final class LiveSession {
        let key: String
        let session: MLXLMCommon.ChatSession
        /// The transcript this session has consumed, *including* the replies it generated.
        var consumed: [(role: String, text: String, images: Int)] = []
        var lastUsed = Date()
        init(key: String, session: MLXLMCommon.ChatSession) {
            self.key = key
            self.session = session
        }
    }

    // [T-nabla-local-mlx-session-pool] More than one conversation can be in flight on the same model.
    // Seen in the device turn log: after each exchange the app asks the engine for a short *title*
    // generation ("You generate concise titles for conversations…") with a different system prompt and a
    // one-message transcript. With a single session slot that request evicted the chat's session — the
    // next chat turn then reported "rebuilt: the transcript is shorter than what this session has already
    // generated" and re-prefilled all ~13k tokens (26 s on the 4B) instead of the new message alone.
    //
    // The app already assumes a stable tools + system prefix: its Anthropic client places
    // `cache_control: ephemeral` on the last tool definition precisely so that "tools + system" are reused
    // across turns (`OAuthHTTPClient.swift`). The same contract holds here, so the conversation identity
    // (model, thinking mode, system prompt) is the right key. Two slots is deliberate — each holds a KV
    // cache for the whole context, so an unbounded pool would trade speed for memory it does not have.
    private var liveSessions: [LiveSession] = []
    private static let maxLiveSessions = 2

    private func liveSession(for key: String) -> LiveSession? {
        guard let i = liveSessions.firstIndex(where: { $0.key == key }) else { return nil }
        let e = liveSessions.remove(at: i)
        e.lastUsed = Date()
        liveSessions.append(e)
        return e
    }

    private func store(_ entry: LiveSession) {
        liveSessions.removeAll { $0.key == entry.key }
        entry.lastUsed = Date()
        liveSessions.append(entry)
        while liveSessions.count > Self.maxLiveSessions {
            // Least recently used first; dropping the object releases its cache.
            liveSessions.removeFirst()
        }
    }

    private func clearSessions() {
        liveSessions.removeAll()
    }

    /// A short stable digest of the system prompt: the conversation identity for the pool and the log.
    static func promptDigest(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "none" }
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100000001b3
        }
        return String(format: "%012llx", h & 0xffffffffffff)
    }""")

# ─────────────────────────────────────────────────────────────────────────────
# 2. Use the pool in stream().
# ─────────────────────────────────────────────────────────────────────────────
t = t.replace("""        let key = "\\(id)|\\(thinking)"
        if sessionKey != key { session = nil; consumed = [] }""",
"""        // The conversation identity: model + thinking mode + the system prompt text (the app keeps the
        // latter stable within a conversation — that is what its own Anthropic cache breakpoints assume).
        let key = "\\(id)|\\(thinking)|\\(Self.promptDigest(system))"
        let existing = liveSession(for: key)""")

t = t.replace("""        var continues = false
        var reuseNote = "new session"
        if session != nil, sessionKey == key {
            switch Self.compare(consumed: consumed, prior: prior) {""",
"""        var continues = false
        var reuseNote = "new session"
        if let existing {
            switch Self.compare(consumed: existing.consumed, prior: prior) {""")

t = t.replace("""            case .matches:
                continues = true
                reuseNote = "continuing the session (\\(consumed.count) messages cached)\"""",
"""            case .matches:
                continues = true
                reuseNote = "continuing the session (\\(existing.consumed.count) messages cached)\"""")

t = t.replace("""        } else if session != nil {
            reuseNote = "rebuilt: model or thinking mode changed"
        }

        let s: MLXLMCommon.ChatSession
        if continues, let live = session {
            // Hand the live session the current prompt and tool set: it re-renders its leading messages
            // from these every call, so this is how a changed system prompt is applied without losing the
            // cache. Leaving them stale would silently answer from the previous turn's instructions.
            live.instructions = system
            live.tools = tools
            s = live
        } else {""",
"""        }

        // Whichever session this turn runs in — a continued one or the replacement for this key.
        let target: LiveSession
        if continues, let existing {
            // Hand the live session the current prompt and tool set: it re-renders its leading messages
            // from these every call, so this is how a changed system prompt is applied without losing the
            // cache. Leaving them stale would silently answer from the previous turn's instructions.
            existing.session.instructions = system
            existing.session.tools = tools
            target = existing
        } else {""")

t = t.replace("""            s = MLXLMCommon.ChatSession(
                c, instructions: system,
                history: prior.map(Self.message),
                generateParameters: params,
                additionalContext: info.thinkingCapable
                    ? (["enable_thinking": thinking] as [String: any Sendable]) : nil,
                tools: tools)
            session = s
        }
        sessionKey = key
        s.generateParameters = params""",
"""            let fresh = MLXLMCommon.ChatSession(
                c, instructions: system,
                history: prior.map(Self.message),
                generateParameters: params,
                additionalContext: info.thinkingCapable
                    ? (["enable_thinking": thinking] as [String: any Sendable]) : nil,
                tools: tools)
            target = LiveSession(key: key, session: fresh)
            store(target)
        }
        let s = target.session
        s.generateParameters = params""")

t = t.replace("""        // The session now holds the prompt and this reply; the next turn must extend exactly this.
        consumed = history.map { ($0.role, $0.text, $0.images.count) }
            + [("assistant", Self.visibleText(out), 0)]""",
"""        // The session now holds the prompt and this reply; the next turn must extend exactly this.
        target.consumed = history.map { ($0.role, $0.text, $0.images.count) }
            + [("assistant", Self.visibleText(out), 0)]""")

# The benchmark wants a cold engine each pass, and unload must release every cache.
t = t.replace("""        // A fresh session every time: reusing one would reuse a cache and flatter the number.
        session = nil; sessionKey = nil; consumed = []""",
"""        // A fresh session every time: reusing one would reuse a cache and flatter the number.
        clearSessions()""")

# Report the stop reason honestly: the app can only tell the user "the model ran out of output tokens"
# if the engine says so, and `maxTokensHit` was hardcoded to false.
t = t.replace("""        let started = Date()""",
"""        LocalTurnLog.note("turn budget=\\(maxTokens) key=\\(key)")
        let started = Date()""")
t = t.replace("""        onEvent(.done(maxTokensHit: false))""",
"""        onEvent(.done(maxTokensHit: stats.generatedTokens >= maxTokens))""")
p.write_text(t)

# Remaining references to the old fields.
left = [(i + 1, l) for i, l in enumerate(t.splitlines())
        if ("sessionKey" in l or "consumed" in l or "session = " in l or " session." in l)
        and "LiveSession" not in l and "//" not in l.strip()[:2]]
print("host braces:", t.count('{') - t.count('}'))
print("possible leftovers:")
for n, l in left:
    print(f"  {n}: {l.strip()[:110]}")
