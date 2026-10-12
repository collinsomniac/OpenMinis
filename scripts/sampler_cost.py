import pathlib

p = pathlib.Path('Providers/LocalMLX/LocalModelHost.swift')
t = p.read_text()

# ── 1. Sampling preference: the checkpoint's own truncation, or greedy. ──
t = t.replace("""enum LocalKVCachePreference: Hashable {""",
"""/// Which logit filter the engine applies when choosing the next token.
///
/// [T-nabla-local-mlx-sampler-cost] This is a real speed setting, not a taste setting. MLX selects its
/// sampler from which filters are active (`GenerateParameters.sampler()`): `temperature == 0` gives
/// `ArgMaxSampler` (free), no filter at all gives `CategoricalSampler` (softmax + one draw), and **any** of
/// topP/topK/minP gives `TopPSampler`, which implements truncation with a full-vocabulary sort
/// (151,936 entries for Qwen3, 248,320 for Qwen3.5) plus a scatter — once per generated token. Most
/// checkpoints declare `top_k`, so a chat turn is very likely paying that per token.
///
/// "Model sampling" is the honest default (it is what the checkpoint asks for, and a 0.6B needs the
/// truncation). Greedy exists so the cost is measurable on a real turn rather than argued about.
enum LocalSamplingPreference: String, CaseIterable {
    case model
    case greedy

    static let key = "nabla.localInference.sampling"

    static var current: LocalSamplingPreference {
        LocalSamplingPreference(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .model
    }
}

enum LocalKVCachePreference: Hashable {""")

t = t.replace("""        let sampling = info.sampling
        params.temperature = temperature ?? sampling.temperature""",
"""        let sampling = info.sampling
        let preferGreedy = LocalSamplingPreference.current == .greedy
        params.temperature = preferGreedy ? 0 : (temperature ?? sampling.temperature)""")
t = t.replace("""        // 1.0 unless the model asked for a small top-p AND has no cheaper filter to use instead.
        params.topP = sampling.topP
        params.topK = sampling.topK
        params.minP = sampling.minP
        params.repetitionPenalty = sampling.repetitionPenalty""",
"""        // 1.0 unless the model asked for a small top-p AND has no cheaper filter to use instead. Note
        // that `topK` alone still routes MLX to the sort-based sampler, so this only removes the top-p
        // half of the cost; the Sampling setting is what removes the rest.
        params.topP = preferGreedy ? 1.0 : sampling.topP
        params.topK = preferGreedy ? 0 : sampling.topK
        params.minP = preferGreedy ? 0 : sampling.minP
        params.repetitionPenalty = sampling.repetitionPenalty""")

# ── 2. Benchmark: measure both sampler paths in one tap. ──
old = t[t.index("    func benchmark(_ id: String, contextTokens: Int = 0, maxTokens: Int = 128) async throws -> LocalGenStats {"):t.index("    /// How the app's transcript relates to what this session has already consumed.")]
new = '''    func benchmark(_ id: String, contextTokens: Int = 0, maxTokens: Int = 128) async throws -> LocalGenStats {
        LocalTurnLog.note("benchmark start \\(id) ctx=\\(contextTokens) kv=\\(LocalKVCachePreference.current.displayBits)")

        // Two passes, because the difference between them *is* the sampler's cost: the first is argmax
        // (no filter, no sort), the second is what the checkpoint actually asks for. Reporting only one of
        // them either hides the cost or overstates what a real turn achieves.
        let greedy = try await runBenchmark(id, contextTokens: contextTokens,
                                            maxTokens: maxTokens, greedy: true)
        let sampled = try await runBenchmark(id, contextTokens: contextTokens,
                                             maxTokens: maxTokens, greedy: false)

        var out = greedy
        out.sampledDecodeTokensPerSecond = sampled.decodeTokensPerSecond
        out.sampledTokensPerSecondIsSamePath = abs(sampled.decodeTokensPerSecond - greedy.decodeTokensPerSecond) < 0.05
        return out
    }

    private func runBenchmark(_ id: String, contextTokens: Int, maxTokens: Int,
                              greedy: Bool) async throws -> LocalGenStats {
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
        let previous = LocalSamplingPreference.current
        UserDefaults.standard.set(greedy ? LocalSamplingPreference.greedy.rawValue
                                         : LocalSamplingPreference.model.rawValue,
                                  forKey: LocalSamplingPreference.key)
        defer { UserDefaults.standard.set(previous.rawValue, forKey: LocalSamplingPreference.key) }
        try await stream(modelId: id, system: nil, history: history,
                         maxTokens: maxTokens, temperature: nil, thinking: false) { ev in
            if case .done = ev {}
        }
        return await MainActor.run { LocalEngineState.shared.lastStats } ?? LocalGenStats(model: id)
    }

'''
t = t.replace(old, new)

# Stats carry the second number.
t = t.replace("""    /// Why this turn did or was not reuse""", """    /// Decode rate with the checkpoint's own sampling, measured alongside the greedy pass.
    var sampledDecodeTokensPerSecond: Double = 0
    var sampledTokensPerSecondIsSamePath = false
    /// Why this turn did or was not reuse""")
p.write_text(t)
print("host:", t.count('{') - t.count('}'))

# ── 3. Surface it in Performance, and expose the setting. ──
s = pathlib.Path('Views/Settings/LocalInferenceSettingsView.swift'); u = s.read_text()
u = u.replace("""            if let b = model.benchResult {
                statRow(AppLocalized("Benchmark"), value: speed(b.decodeTokensPerSecond),
                        detail: AppLocalized("short prompt, no history"))
            }""",
"""            if let b = model.benchResult {
                statRow(AppLocalized("Benchmark"), value: speed(b.decodeTokensPerSecond),
                        detail: b.sampledTokensPerSecondIsSamePath
                            ? AppLocalized("short prompt, no history")
                            : "\\(AppLocalized("greedy")) · \\(speed(b.sampledDecodeTokensPerSecond)) \\(AppLocalized("with model sampling"))")
            }""")
u = u.replace("""            if let b = model.benchContextResult {
                statRow(AppLocalized("Benchmark @ 8k"), value: speed(b.decodeTokensPerSecond),
                        detail: "\\(b.promptTokens) tok prompt · \\(Int(b.prefillTokensPerSecond)) tok/s prefill · KV \\(b.kvBits)-bit")
            }""",
"""            if let b = model.benchContextResult {
                statRow(AppLocalized("Benchmark @ 8k"), value: speed(b.decodeTokensPerSecond),
                        detail: "\\(b.promptTokens) tok prompt · \\(Int(b.prefillTokensPerSecond)) tok/s prefill · KV \\(b.kvBits)-bit"
                            + (b.sampledTokensPerSecondIsSamePath ? "" : " · \\(speed(b.sampledDecodeTokensPerSecond)) sampled"))
            }""")

# The setting itself, in the KV section where the other engine knobs live.
u = u.replace("""            Button {
                model.measure(engine.residentModelId ?? model.models.first?.id ?? "", contextTokens: 8192)""",
"""            Picker(AppLocalized("Sampling"), selection: Binding(
                get: { model.sampling },
                set: { newValue in
                    model.sampling = newValue
                    UserDefaults.standard.set(newValue.rawValue, forKey: LocalSamplingPreference.key)
                })) {
                Text(AppLocalized("Model default")).tag(LocalSamplingPreference.model)
                Text(AppLocalized("Greedy (fastest)")).tag(LocalSamplingPreference.greedy)
            }
            Button {
                model.measure(engine.residentModelId ?? model.models.first?.id ?? "", contextTokens: 8192)""")

u = u.replace("""    @Published var kvPrecision: LocalKVCachePreference""",
"""    @Published var sampling: LocalSamplingPreference = LocalSamplingPreference.current
    @Published var kvPrecision: LocalKVCachePreference""")
s.write_text(u)
print("settings braces:", u.count('{') - u.count('}'))
print("kvPrecision decl found:", "@Published var kvPrecision" in u)
