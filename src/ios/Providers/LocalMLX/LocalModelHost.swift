import Foundation
import CoreImage
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import MLXVLM
import HuggingFace
import Tokenizers

// LocalMLX — run the agent on the phone's GPU.
//
// [T-nabla-local-mlx-residency] **One model, admitted deliberately.** This engine owns the single
// resident model. Nothing else may load one, and loading is refused unless the model can actually fit:
// the 4B models this library can hold are 5.16 GB of weights against a ~6.4 GB per-process ceiling, so
// an unbudgeted load is not a slow path, it is a jetsam kill. Device crash reports showed exactly that
// (`reason=per-process-limit, rpages≈6.46 GB, states=[active, frontmost]`) after a 5.16 GB model was
// resident and another load began. A hard failure with a readable explanation is strictly better than
// the process dying, so `load` estimates first and refuses when the numbers do not work.
//
// Ported from LoopLab (github.com/collinsomniac/looplab). Needs the
// com.apple.developer.kernel.increased-memory-limit entitlement: ~6 GB usable instead of ~3.25 GB,
// which measured as a ~3x decode-speed difference on an iPhone 17 Pro Max.

// MARK: - Engine

/// A turn's measurements, so "it feels slow" can be answered with numbers.
struct LocalGenStats: Sendable, Codable {
    var model: String = ""
    var promptTokens: Int = 0
    /// Prompt tokens this turn did NOT prefill, because the session already represented them.
    var reusedTokens: Int = 0
    var prefillSeconds: Double = 0
    var generatedTokens: Int = 0
    var decodeSeconds: Double = 0
    var timeToFirstToken: Double = 0
    var cancelled = false
    /// Context tokens this turn's cache held, and the KV bytes they imply.
    var contextTokens: Int = 0
    var kvBytesPerToken: Int = 0
    var kvBits: Int = 16
    /// Why this turn did or did not reuse the session's prompt cache. Shown in Performance: "0 reused" has
    /// several very different causes (a new session, a rewritten transcript, a system prompt that changed
    /// above the cached prefix) and they need different fixes, so the decision explains itself.
    var reuseNote: String = ""

    var prefillTokensPerSecond: Double { prefillSeconds > 0 ? Double(promptTokens - reusedTokens) / prefillSeconds : 0 }
    var cacheHitRatio: Double { promptTokens > 0 ? Double(reusedTokens) / Double(promptTokens) : 0 }
    var decodeTokensPerSecond: Double { decodeSeconds > 0 ? Double(generatedTokens) / decodeSeconds : 0 }
}

/// Main-actor mirror of the engine's residency. SwiftUI reads this; the actor writes it.
///
/// Kept separate from the actor so view code can ask "is the selected model loaded?" synchronously —
/// which is what the send-time confirmation needs — without hopping onto the engine.
@MainActor
final class LocalEngineState: ObservableObject {
    static let shared = LocalEngineState()
    @Published var residentModelId: String?
    @Published var loadingModelId: String?
    @Published var lastError: String?
    @Published var lastStats: LocalGenStats?
    /// The engine's last refusal, verbatim — shown so a refused load explains itself.
    @Published var lastRefusal: String?

    var hasResident: Bool { residentModelId != nil }
}

actor LocalModelHost {
    static let shared = LocalModelHost()

    private(set) var modelId: String?
    private var container: ModelContainer?
    private var containerIsVLM = false
    private var session: MLXLMCommon.ChatSession?
    private var sessionKey: String?
    /// The transcript the live session has already consumed, *including* the reply it generated.
    private var consumed: [(role: String, text: String, images: Int)] = []
    private var activeTask: Task<Void, Error>?

    // MARK: Residency

    func status() -> LocalHostStatus {
        LocalHostStatus(modelId: modelId, resident: container != nil)
    }

    /// Free the resident model and give the memory back. Awaited by `load` before admitting another.
    func unload() async {
        activeTask?.cancel()
        activeTask = nil
        session = nil
        sessionKey = nil
        consumed = []
        container = nil
        containerIsVLM = false
        modelId = nil
        Memory.clearCache()
        await publishResidency(model: nil, loading: nil)
    }

    /// Load `id`, refusing when it cannot fit.
    ///
    /// [T-nabla-local-mlx-admission] The estimate is deliberately conservative and simple: the weights on
    /// disk, plus one third again for KV/activations at the configured context, must fit in available
    /// memory once the current model has been released. `os_proc_available_memory()` reports what is
    /// left before the jetsam limit, so the check is against the real ceiling rather than physical RAM.
    func load(_ id: String, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ModelContainer {
        if modelId == id, let c = container {
            // Already resident — but publish anyway: this is the path the UI takes when the user
            // taps Load on a model the engine already holds, and it must confirm that.
            await publishResidency(model: id, loading: nil)
            await publishRefusal(nil)
            return c
        }
        let dir = LocalModelStore.dir(for: id)
        guard LocalModelStore.isModelDir(dir) else { throw LocalModelError.notInstalled(id) }

        // Release the previous model FIRST, then measure — otherwise the check is against memory we are
        // about to free, and every second load would be refused.
        await unload()
        await publishResidency(model: nil, loading: id)

        let info = LocalModelStore.profile(dir)
        if info.kind == .unsupported {
            await publishResidency(model: nil, loading: nil)
            throw LocalModelError.notInstalled("\(id) (\(info.modelType) is not a chat architecture)")
        }
        // Size the check against the context this model will actually run at: its trained context is
        // often far larger than a phone can hold K/V for, and it is the KV term that decides.
        let kvPref = LocalKVCachePreference.current
        let budgetContext = min(info.contextLength ?? 8192, LocalKVCachePreference.assumedContextTokens)
        let need = LocalModelStore.runCost(for: info, contextTokens: budgetContext, kvBits: kvPref.displayBits)
        let have = Int64(os_proc_available_memory())
        guard need <= have else {
            await publishResidency(model: nil, loading: nil)
            let message = LocalModelError.outOfMemory(needBytes: need, haveBytes: have, model: info.name)
                .errorDescription ?? "not enough memory"
            await publishRefusal(message)
            throw LocalModelError.outOfMemory(needBytes: need, haveBytes: have, model: info.name)
        }
        await publishRefusal(nil)

        LocalModelStore.normalizeTokenizer(in: dir)
        // [T-nabla-local-mlx-memory] A small buffer cache on purpose. LoopLab measured 164 tok/s on
        // Qwen3-0.6B with a 64 MB limit; a large pool is not a speed win and is memory the KV cache
        // and activations may need on a 4B model.
        Memory.cacheLimit = 64 * 1024 * 1024

        // A VLM must be built by the VLM factory or its vision tower stays dead weight and it cannot
        // see an image at all — which is what made a multimodal model reach for a screenshot tool.
        let c: ModelContainer
        if info.kind == .vision {
            c = try await VLMModelFactory.shared.loadContainer(from: dir, using: #huggingFaceTokenizerLoader())
            containerIsVLM = true
        } else {
            c = try await LLMModelFactory.shared.loadContainer(from: dir, using: #huggingFaceTokenizerLoader())
            containerIsVLM = false
        }
        container = c
        modelId = id
        containerIsVLM = (info.kind == .vision)
        await publishResidency(model: id, loading: nil)
        return c
    }

    // MARK: Generation

    /// Stream one assistant turn.
    ///
    /// Cache policy: keep the live `ChatSession` and **append** the new messages to it, which is what the
    /// API is built for — a session owns its KV cache and trims it to the longest common prefix with the
    /// new prompt (see `ChatSession`'s prompt-cache policy). Rebuilding from a full history instead
    /// re-prefills the entire transcript, and with this app's ~6.6k-token system prompt that is the
    /// difference between a fast turn and a slow one.
    func stream(modelId id: String, system: String?, history: [LocalTurn],
                maxTokens: Int, temperature: Float?, thinking: Bool,
                tools: [[String: any Sendable]]? = nil,
                onEvent: @escaping @Sendable (LocalEvent) -> Void) async throws {
        let c = try await load(id)
        let info = LocalModelStore.profile(LocalModelStore.dir(for: id))

        var params = GenerateParameters(maxTokens: maxTokens)
        // [T-nabla-local-mlx-kv-precision] The single biggest lever on decode speed at long context, and
        // it is a supported MLX parameter rather than a trick: `kvBits` selects an affine KV cache plan
        // (GenerateParameters.kvCachePlan() → KVCacheConfiguration.Strategy.affine), `quantizedKVStart`
        // keeps K/V in full precision for the first N tokens. Halving KV bytes halves the per-token read
        // that dominates at long context, while a short conversation pays nothing.
        let kv = LocalKVCachePreference.current
        // Only ask for a quantised cache when one was actually chosen: passing a width for "full" makes
        // MLX build a plan it cannot apply, and the failure is swallowed.
        if let bits = kv.bits {
            params.kvBits = bits
            params.kvGroupSize = 64
            params.quantizedKVStart = kv.startTokens
        }
        let sampling = info.sampling
        params.temperature = temperature ?? sampling.temperature
        // 1.0 unless the model asked for a small top-p AND has no cheaper filter to use instead.
        params.topP = sampling.topP
        params.topK = sampling.topK
        params.minP = sampling.minP
        params.repetitionPenalty = sampling.repetitionPenalty

        // [T-nabla-local-mlx-session-policy] Only the model and the thinking mode force a new session.
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
        let key = "\(id)|\(thinking)"
        if sessionKey != key { session = nil; consumed = [] }

        // The new input is everything after the last assistant turn: one user message normally, or a
        // batch of tool results after the model called tools. `streamDetails(to:)` takes a batch.
        let splitIndex = (history.lastIndex(where: { $0.role == "assistant" }).map { $0 + 1 }) ?? max(0, history.count - 1)
        let prior = Array(history[..<splitIndex])
        let newTurns = history.count > splitIndex ? Array(history[splitIndex...])
                                                  : [LocalTurn(role: "user", text: "")]
        let newMessages = newTurns.map(Self.message)

        // Reuse the live session when this request continues it by at least its consumed prefix: the
        // agent loop re-sends the whole transcript every turn, so the common case is "same prefix plus
        // one or more new messages", not "identical prefix plus exactly one".
        var continues = false
        var reuseNote = "new session"
        if session != nil, sessionKey == key {
            switch Self.compare(consumed: consumed, prior: prior) {
            case .matches:
                continues = true
                reuseNote = "continuing the session (\(consumed.count) messages cached)"
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
                reuseNote = "rebuilt: history message \(at) differs (\(what))"
            }
        } else if session != nil {
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
        } else {
            // `tools` without `toolDispatch`: ChatSession then emits `Generation.toolCall` and returns,
            // leaving execution to the caller — which is exactly the app's agent loop. MLX renders the
            // schemas through the model's OWN chat template and parses calls with the format inferred
            // from that template (`ToolCallFormat.inferred(fromChatTemplate:)`), so this stays generic
            // across model families instead of growing a branch per family.
            s = MLXLMCommon.ChatSession(
                c, instructions: system,
                history: prior.map(Self.message),
                generateParameters: params,
                additionalContext: info.thinkingCapable
                    ? (["enable_thinking": thinking] as [String: any Sendable]) : nil,
                tools: tools)
            session = s
        }
        sessionKey = key
        s.generateParameters = params

        let started = Date()
        var firstTokenAt: Date?
        var gen = 0
        var out = ""
        var stats = LocalGenStats(model: id)
        var toolCallsThisTurn: [MLXLMCommon.ToolCall] = []
        stats.model = id
        stats.kvBytesPerToken = info.kvBytesPerToken
        stats.kvBits = kv.displayBits
        stats.reuseNote = reuseNote

        // [T-nabla-local-mlx-thinking-tags] The tags are built from parts on purpose. Written literally
        // in source they survived a file write mangled into the bare words (` thinking` → `thinking`),
        // which made the splitter match ordinary prose and never match a real tag.
        let openTag = "<" + "think" + ">"
        let closeTag = "<" + "/" + "think" + ">"
        // A thinking-enabled Qwen template PREFILLS the open tag into the generation prompt, so the
        // streamed text begins inside the reasoning block and only the closing tag arrives. Starting the
        // parser in the matching state is what makes reasoning render as a collapsible block instead of
        // leaking into the answer.
        var inThink = thinking && info.thinkingCapable
        var pending = ""

        // Coalesce UI deltas: at 160 tok/s a yield per token is 160 main-actor hops a second, and the
        // message view re-renders its markdown on each one. ~30 Hz is visually identical and far cheaper.
        var textBuf = "", thinkBuf = ""
        var lastFlush = Date()
        func flush(force: Bool = false) {
            let now = Date()
            guard force || now.timeIntervalSince(lastFlush) >= 0.033 else { return }
            if !thinkBuf.isEmpty { onEvent(.thinking(thinkBuf)); thinkBuf = "" }
            if !textBuf.isEmpty { onEvent(.text(textBuf)); textBuf = "" }
            lastFlush = now
        }

        let task = Task {
            for try await g in s.streamDetails(to: newMessages) {
                try Task.checkCancellation()
                if let chunk = g.chunk {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    gen += 1
                    out += chunk
                    pending += chunk
                    while !pending.isEmpty {
                        if inThink {
                            if let r = pending.range(of: closeTag) {
                                thinkBuf += String(pending[..<r.lowerBound])
                                pending = String(pending[r.upperBound...])
                                inThink = false
                            } else {
                                // Hold a possible partial tag at the tail.
                                let keep = min(closeTag.count - 1, pending.count)
                                let cut = pending.index(pending.endIndex, offsetBy: -keep)
                                thinkBuf += String(pending[..<cut]); pending = String(pending[cut...])
                                break
                            }
                        } else {
                            if let r = pending.range(of: openTag) {
                                textBuf += String(pending[..<r.lowerBound])
                                pending = String(pending[r.upperBound...])
                                inThink = true
                            } else {
                                let keep = min(openTag.count - 1, pending.count)
                                let cut = pending.index(pending.endIndex, offsetBy: -keep)
                                textBuf += String(pending[..<cut]); pending = String(pending[cut...])
                                break
                            }
                        }
                    }
                    flush()
                }
                if case .toolCall(let call) = g {
                    flush(force: true)
                    let args = call.function.arguments.mapValues { $0.anyValue }
                    let json = (try? JSONSerialization.data(withJSONObject: args))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    onEvent(.toolCall(id: call.id ?? "call_\(UUID().uuidString.prefix(8))",
                                      name: call.function.name, argumentsJSON: json))
                    toolCallsThisTurn.append(call)
                }
                if let info = g.info {
                    stats.promptTokens = info.totalPromptTokenCount
                    stats.reusedTokens = max(0, info.totalPromptTokenCount - info.promptTokenCount)
                    stats.prefillSeconds = info.promptTime
                    stats.generatedTokens = info.generationTokenCount
                    stats.decodeSeconds = info.generateTime
                    onEvent(.usage(input: info.totalPromptTokenCount, output: info.generationTokenCount,
                                   tokensPerSecond: info.generateTime > 0
                                       ? Double(info.generationTokenCount) / info.generateTime : 0))
                }
            }
            flush(force: true)
        }
        activeTask = task
        do {
            try await task.value
        } catch {
            activeTask = nil
            stats.cancelled = error is CancellationError
            throw error
        }
        activeTask = nil

        // The session now holds the prompt and this reply; the next turn must extend exactly this.
        consumed = history.map { ($0.role, $0.text, $0.images.count) }
            + [("assistant", Self.visibleText(out), 0)]
        _ = toolCallsThisTurn
        stats.timeToFirstToken = (firstTokenAt ?? Date()).timeIntervalSince(started)
        stats.contextTokens = stats.promptTokens + stats.generatedTokens
        await publishStats(stats)
        LocalTurnLog.turn(
            model: id, thinking: thinking,
            kv: "\(kv.displayBits)|\(kv.startTokens)",
            system: system, history: history, note: reuseNote,
            promptTokens: stats.promptTokens, reusedTokens: stats.reusedTokens,
            prefillMs: Int(stats.prefillSeconds * 1000), decodeMs: Int(stats.decodeSeconds * 1000),
            generated: stats.generatedTokens)
        onEvent(.done(maxTokensHit: false))
    }

    /// Measure decode speed on a short prompt, with no transcript to prefill.
    ///
    /// Deliberately NOT a chat: a fixed, tiny prompt isolates the engine from the agent loop, from this
    /// app's ~6.6k-token system prompt, and from the UI. That separation is the whole point — it answers
    /// "is the model slow, or is everything around it slow?".
    /// Measure the engine with no history, optionally behind a large synthetic prompt.
    ///
    /// A short-prompt benchmark is the engine's ceiling and says nothing about the case the app is
    /// actually in: at ~11.5k tokens of agent prompt, the per-token read is dominated by the KV cache, and
    /// that is the term the KV precision setting exists to change. Measuring both, at the same device
    /// temperature, is what makes the two comparable — and it is the only way to tell whether quantising
    /// K/V helps or hurts, since MLX's quantised attention path dequantises before the matmul.
    func benchmark(_ id: String, contextTokens: Int = 0, maxTokens: Int = 128) async throws -> LocalGenStats {
        LocalTurnLog.note("benchmark start \(id) ctx=\(contextTokens) kv=\(LocalKVCachePreference.current.displayBits)")
        var stats = LocalGenStats(model: id)
        var text = "Count from 1 to 40 in words, comma separated."
        if contextTokens > 0 {
            // The engine reports the exact prompt length, so this only has to be approximately right.
            let phrase = "The quick brown fox jumps over the lazy dog beside the river at dawn. "
            let repeats = max(1, (contextTokens * 4) / phrase.count)
            text = String(repeating: phrase, count: repeats)
                + "\nIgnore the text above. Count from 1 to 40 in words, comma separated."
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

    /// How the app's transcript relates to what this session has already consumed.
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
            if was.role != now.role { return .differs(at: i, what: "role \(was.role)→\(now.role)") }
            if !sameImages { return .differs(at: i, what: "image count") }
            return .differs(at: i, what: "text")
        }
        return .matches
    }

    private static func message(_ t: LocalTurn) -> MLXLMCommon.Chat.Message {
        let images: [UserInput.Image] = t.images.compactMap { data in
            CIImage(data: data).map { UserInput.Image.ciImage($0) }
        }
        switch t.role {
        case "assistant":
            let calls: [MLXLMCommon.ToolCall] = t.toolCalls.map { c in
                let obj = (try? JSONSerialization.jsonObject(with: Data(c.argumentsJSON.utf8))) as? [String: Any] ?? [:]
                let args = obj.mapValues { Self.sendable($0) }
                return MLXLMCommon.ToolCall(function: .init(name: c.name, arguments: args), id: c.id)
            }
            return .assistant(t.text, toolCalls: calls.isEmpty ? nil : calls)
        case "tool":
            return .tool(t.text, id: t.toolCallId, name: t.toolName)
        default:
            return .user(t.text, images: images)
        }
    }

    /// JSONSerialization hands back Foundation types; ToolCall wants Sendable values it can encode.
    private static func sendable(_ v: Any) -> any Sendable {
        switch v {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return n.doubleValue.rounded() == n.doubleValue && abs(n.doubleValue) < 1e15 ? n.intValue : n.doubleValue
        case let a as [Any]: return a.map { sendable($0) }
        case let d as [String: Any]: return d.mapValues { sendable($0) }
        default: return String(describing: v)
        }
    }

    /// The reply as the transcript records it: reasoning stripped (the app stores the answer, not the
    /// trace), so the reuse comparison on the next turn matches what the app sends back.
    private static func visibleText(_ raw: String) -> String {
        let open = "<" + "think" + ">", close = "<" + "/" + "think" + ">"
        var out = raw
        if let c = out.range(of: close) {
            if let o = out.range(of: open), o.lowerBound < c.lowerBound {
                out.removeSubrange(o.lowerBound..<c.upperBound)
            } else {
                out.removeSubrange(out.startIndex..<c.upperBound)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Residency is published on EVERY path that changes it, including the early return in `load`.
    ///
    /// [T-nabla-local-mlx-state-drift] These used to share one `publish(model:loading:stats:)` whose
    /// `model`/`loading` had default values — so `publish(stats:)` at the end of a turn ALSO set
    /// `residentModelId = nil`. The engine still held the model while the UI believed nothing was
    /// loaded: the settings row offered "Load" for a resident model, the send gate claimed "not loaded",
    /// and tapping Load hit `load`'s early return (`modelId == id`) which published nothing — so the
    /// state could never recover. One field per concern makes that impossible.
    private func publishResidency(model: String?, loading: String?) async {
        await MainActor.run {
            let st = LocalEngineState.shared
            st.residentModelId = model
            st.loadingModelId = loading
        }
    }

    private func publishStats(_ stats: LocalGenStats) async {
        await MainActor.run { LocalEngineState.shared.lastStats = stats }
    }

    private func publishRefusal(_ message: String?) async {
        await MainActor.run { LocalEngineState.shared.lastRefusal = message }
    }
}

/// The user's KV-cache precision choice, and the defaults derived from it.
///
/// [T-nabla-local-mlx-kv-precision] Explained as a latency control in Settings, because that is what it
/// is: K/V is re-read for every generated token, so its size sets the decode rate once the conversation
/// is long. Full precision is the quality-safe default for short chats; quantisation is where the long
/// -context speed comes from.
enum LocalKVCachePreference: Hashable {
    /// The context a fit check should assume when a model's own maximum is far beyond what fits.
    static let assumedContextTokens = 8192

    case full
    case eightBit(from: Int)
    case fourBit(from: Int)

    static var current: LocalKVCachePreference {
        switch UserDefaults.standard.string(forKey: key) {
        case "full": return .full
        case "4": return .fourBit(from: Int(UserDefaults.standard.double(forKey: startKey)))
        default: return .eightBit(from: Int(UserDefaults.standard.double(forKey: startKey)))
        }
    }

    static let key = "nabla.localInference.kvPrecision"
    static let startKey = "nabla.localInference.kvStartTokens"

    /// Bits for MLX, where **nil means no quantization at all** (`GenerateParameters.kvBits` is `Int?`,
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
    var displayBits: Int { bits ?? 16 }

    var startTokens: Int {
        switch self {
        case .full: return 0
        case .eightBit(let n), .fourBit(let n): return max(0, n)
        }
    }

    var label: String {
        switch self {
        case .full: return "Full precision"
        case .eightBit(let n): return n > 0 ? "8-bit after \(n) tokens" : "8-bit"
        case .fourBit(let n): return n > 0 ? "4-bit after \(n) tokens" : "4-bit"
        }
    }
}

/// A deliberately plain, append-only record of what each turn actually sent.
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
                try handle.write(contentsOf: data + Data("\n".utf8))
            } else {
                try (data + Data("\n".utf8)).write(to: file)
            }
        } catch {
            // A diagnostic must never break a turn.
        }
    }
}

/// One turn of the transcript, carrying any images the model must actually see.
struct LocalTurn: Sendable {
    let role: String
    let text: String
    var images: [Data] = []
    /// Assistant turns: the structured calls the model made (rendered back into the template as real
    /// tool calls, not as prose — a model that sees its own calls as text learns to write text).
    var toolCalls: [LocalToolCall] = []
    /// Tool-role turns: which call this result answers.
    var toolCallId: String? = nil
    var toolName: String? = nil
}

/// A tool call in a form both the app and MLX can carry.
struct LocalToolCall: Sendable {
    let id: String
    let name: String
    /// JSON object text; decoded on the MLX side into `[String: JSONValue]`.
    let argumentsJSON: String
}

enum LocalEvent: Sendable {
    /// The model asked for a tool. The app's own agent loop executes it and sends the result back as a
    /// tool-role turn — the same loop every other provider uses.
    case toolCall(id: String, name: String, argumentsJSON: String)
    case cache(reused: Bool, cachedMessages: Int)
    case text(String)
    case thinking(String)
    case usage(input: Int, output: Int, tokensPerSecond: Double)
    case done(maxTokensHit: Bool)
}

/// What the engine is currently holding, for the settings page.
struct LocalHostStatus: Sendable {
    var modelId: String?
    var resident: Bool
}
