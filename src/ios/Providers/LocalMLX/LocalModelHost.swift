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
struct LocalGenStats: Sendable {
    var model: String = ""
    var promptTokens: Int = 0
    /// Prompt tokens this turn did NOT prefill, because the session already represented them.
    var reusedTokens: Int = 0
    var prefillSeconds: Double = 0
    var generatedTokens: Int = 0
    var decodeSeconds: Double = 0
    var timeToFirstToken: Double = 0
    var cancelled = false

    var prefillTokensPerSecond: Double { prefillSeconds > 0 ? Double(promptTokens - reusedTokens) / prefillSeconds : 0 }
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
    private var activeTask: Task<Void, Never>?

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
        await publish(model: nil, loading: nil)
    }

    /// Load `id`, refusing when it cannot fit.
    ///
    /// [T-nabla-local-mlx-admission] The estimate is deliberately conservative and simple: the weights on
    /// disk, plus one third again for KV/activations at the configured context, must fit in available
    /// memory once the current model has been released. `os_proc_available_memory()` reports what is
    /// left before the jetsam limit, so the check is against the real ceiling rather than physical RAM.
    func load(_ id: String, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ModelContainer {
        if modelId == id, let c = container { return c }
        let dir = LocalModelStore.dir(for: id)
        guard LocalModelStore.isModelDir(dir) else { throw LocalModelError.notInstalled(id) }

        // Release the previous model FIRST, then measure — otherwise the check is against memory we are
        // about to free, and every second load would be refused.
        await unload()
        await publish(model: nil, loading: id)

        let info = LocalModelStore.profile(dir)
        if info.kind == .unsupported {
            await publish(model: nil, loading: nil)
            throw LocalModelError.notInstalled("\(id) (\(info.modelType) is not a chat architecture)")
        }
        let weights = info.bytes
        let need = Int64(Double(weights) * 1.35)
        let have = Int64(os_proc_available_memory())
        guard need <= have else {
            await publish(model: nil, loading: nil)
            throw LocalModelError.outOfMemory(needBytes: need, haveBytes: have, model: info.name)
        }

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
        await publish(model: id, loading: nil)
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
                onEvent: @escaping @Sendable (LocalEvent) -> Void) async throws {
        let c = try await load(id)
        let info = LocalModelStore.profile(LocalModelStore.dir(for: id))

        var params = GenerateParameters(maxTokens: maxTokens)
        let s = info.sampling
        params.temperature = temperature ?? s.temperature
        params.topP = s.topP            // 1.0 unless the model asked for a small one with no cheaper filter
        params.topK = s.topK
        params.minP = s.minP
        params.repetitionPenalty = s.repetitionPenalty

        let key = "\(id)|\(system ?? "")|\(thinking)"
        if sessionKey != key { session = nil; consumed = [] }

        let prior = Array(history.dropLast())
        let last = history.last ?? LocalTurn(role: "user", text: "")
        let lastMessage = Self.message(last)

        // Reuse the live session when this request continues it by at least its consumed prefix: the
        // agent loop re-sends the whole transcript every turn, so the common case is "same prefix plus
        // one or more new messages", not "identical prefix plus exactly one".
        let continues: Bool
        if session != nil, sessionKey == key, consumed.count <= prior.count {
            continues = zip(consumed, prior).allSatisfy { $0.text == $1.text && $0.role == $1.role && $0.images == $1.images }
        } else {
            continues = false
        }

        let s: MLXLMCommon.ChatSession
        if continues, let live = session {
            s = live
        } else {
            s = MLXLMCommon.ChatSession(
                c, instructions: system,
                history: prior.map(Self.message),
                generateParameters: params,
                additionalContext: info.thinkingCapable
                    ? (["enable_thinking": thinking] as [String: any Sendable]) : nil)
            session = s
        }
        sessionKey = key
        s.generateParameters = params

        let started = Date()
        var firstTokenAt: Date?
        var gen = 0
        var out = ""
        var stats = LocalGenStats(model: id)
        stats.model = id

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
            for try await g in s.streamDetails(to: [lastMessage]) {
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
            + [("assistant", out, 0)]
        stats.timeToFirstToken = (firstTokenAt ?? Date()).timeIntervalSince(started)
        await publish(stats: stats)
        onEvent(.done(maxTokensHit: false))
    }

    /// Measure decode speed on a short prompt, with no transcript to prefill.
    ///
    /// Deliberately NOT a chat: a fixed, tiny prompt isolates the engine from the agent loop, from this
    /// app's ~6.6k-token system prompt, and from the UI. That separation is the whole point — it answers
    /// "is the model slow, or is everything around it slow?".
    func benchmark(_ id: String, maxTokens: Int = 128) async throws -> LocalGenStats {
        var stats = LocalGenStats(model: id)
        let history = [LocalTurn(role: "user", text: "Count from 1 to 40 in words, comma separated.")]
        // A fresh session every time: reusing one would reuse a cache and flatter the number.
        session = nil; sessionKey = nil; consumed = []
        try await stream(modelId: id, system: nil, history: history,
                         maxTokens: maxTokens, temperature: 0, thinking: false) { ev in
            if case .done = ev {}
        }
        let last = await MainActor.run { LocalEngineState.shared.lastStats }
        return last ?? stats
    }

    private static func message(_ t: LocalTurn) -> MLXLMCommon.Chat.Message {
        let images: [UserInput.Image] = t.images.compactMap { data in
            CIImage(data: data).map { UserInput.Image.ciImage($0) }
        }
        if t.role == "assistant" { return .assistant(t.text) }
        return .user(t.text, images: images)
    }

    private func publish(model: String?, loading: String?, stats: LocalGenStats? = nil) async {
        await MainActor.run {
            let st = LocalEngineState.shared
            st.residentModelId = model
            st.loadingModelId = loading
            if let stats { st.lastStats = stats }
        }
    }
}

/// One turn of the transcript, carrying any images the model must actually see.
struct LocalTurn: Sendable {
    let role: String
    let text: String
    var images: [Data] = []
}

enum LocalEvent: Sendable {
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
