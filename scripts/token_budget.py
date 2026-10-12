import pathlib

# ── 1. The provider stops second-guessing the app's context-aware budget. ──
p = pathlib.Path('Providers/LocalMLX/LocalMLXProvider.swift')
t = p.read_text()
t = t.replace("""    var defaultMaxTokens: Int { 4096 }""",
"""    /// What this provider asks for when the model entry has no output cap of its own.
    ///
    /// [T-nabla-local-mlx-budget] This was 4096, and the agent path additionally clamped *whatever the app
    /// asked for* down to 4096 (8192 with thinking). That reproduced the exact bug the app's own
    /// `dynamicMaxTokens` comment warns about: a per-model override set by the user was silently ignored,
    /// and every reply was cut off at the same place regardless of the model or the context. The app
    /// already computes `min(model cap ?? provider default, contextWindow − inputTokens)` with a floor and
    /// a global ceiling, so the provider's job is only to supply an honest default — the limit that
    /// actually binds on a phone is derived by the engine from memory (see `LocalModelHost.stream`).
    var defaultMaxTokens: Int { 8192 }""")
t = t.replace("""        let budget = min(maxTokens, thinking ? 8192 : 4096)""",
"""        // No local clamp: the app's budget is already context-aware, and the engine reduces it further
        // only when the device cannot hold the KV for it (reported in Performance as the output budget).
        let budget = maxTokens""")
p.write_text(t)
print("provider braces:", t.count('{') - t.count('}'))

# ── 2. The engine derives the binding limit from memory, and says so. ──
h = pathlib.Path('Providers/LocalMLX/LocalModelHost.swift')
u = h.read_text()
u = u.replace("""        LocalTurnLog.note("turn budget=\\(maxTokens) key=\\(key)")""",
"""        // [T-nabla-local-mlx-budget] The limit that actually binds on a phone is not a constant: it is how
        // many more tokens of K/V this process can hold next to the weights it has already loaded. Derive
        // it, log it, and show it — so a reply that stops early is explainable rather than mysterious, and
        // a long one is allowed whenever the memory genuinely exists.
        let kvPerToken = Double(info.kvBytesPerToken) * Double(kv.displayBits) / 16.0
        let weightsBytes = Double(LocalModelStore.weightsBytes(LocalModelStore.dir(for: id)))
        let freeBytes = Double(os_proc_available_memory())
        let roomForKV = max(0, freeBytes - weightsBytes)
        // The prompt's own K/V comes first; only what is left can be spent on generated tokens.
        let promptEstimate = Double(history.reduce(0) { $0 + $1.text.count }) / 4.0
        let kvTokensAvailable = kvPerToken > 0 ? (roomForKV / kvPerToken) - promptEstimate : 0
        let memoryBound = Int(max(0, kvTokensAvailable))
        let budget = memoryBound > 0 ? min(maxTokens, max(1024, memoryBound)) : maxTokens
        LocalTurnLog.note("turn budget=\\(budget) requested=\\(maxTokens) memoryBound=\\(memoryBound) kvPerToken=\\(Int(kvPerToken)) key=\\(key)")""")

u = u.replace("""                        maxTokens: budget, temperature: temperature, thinking: thinking,""",
"""                        maxTokens: budget, temperature: temperature, thinking: thinking,""")
u = u.replace("""        var params = GenerateParameters(maxTokens: maxTokens)""",
"""        var params = GenerateParameters(maxTokens: maxTokens)""")

# Report the budget alongside the other per-turn numbers.
u = u.replace("""    /// Decode rate with the checkpoint's own sampling, measured alongside the greedy pass.""",
"""    /// The output budget this turn actually ran with, after the engine's memory bound was applied.
    var tokenBudget: Int = 0
    /// Decode rate with the checkpoint's own sampling, measured alongside the greedy pass.""")
u = u.replace("""        stats.reuseNote = reuseNote""", """        stats.reuseNote = reuseNote
        stats.tokenBudget = maxTokens""")
u = u.replace("""        onEvent(.done(maxTokensHit: stats.generatedTokens >= maxTokens))""",
"""        // Tell the truth about why generation stopped: the app can only offer "continue" or explain a
        // truncated answer if the engine reports that it hit the budget rather than finishing.
        let hitLimit = stats.generatedTokens >= maxTokens
        if hitLimit { LocalTurnLog.note("turn hit the output budget (\\(maxTokens) tokens)") }
        onEvent(.done(maxTokensHit: hitLimit))""")
h.write_text(u)
print("host braces:", u.count('{') - u.count('}'))

# ── 3. Show it in Performance. ──
s = pathlib.Path('Views/Settings/LocalInferenceSettingsView.swift')
v = s.read_text()
v = v.replace("""                if !s.reuseNote.isEmpty {""",
"""                if s.tokenBudget > 0 {
                    LabeledContent(AppLocalized("Output budget")) {
                        Text("\\(s.tokenBudget) tok")
                            .font(.caption.monospaced())
                    }
                }
                if !s.reuseNote.isEmpty {""")
s.write_text(v)
print("settings braces:", v.count('{') - v.count('}'))
