import Foundation

// The on-device model library: what is installed, and what each model can actually do.
//
// [T-nabla-local-mlx-store] Capability detection lives here rather than being guessed at the call site,
// because a local model's capabilities are facts read from its own config.json — not a catalog entry we
// maintain. Getting this wrong is not cosmetic: a vision model loaded as text-only is handed an image
// it cannot see, and OpenMinis's own plumbing then decides the turn is "blind", registers the
// read_image/Vision-Group path instead of native pixels, and the model invents a tool call. That is
// exactly what happened with Qwen3.5-4B before this file existed.

/// What a model directory contains, and therefore what can be done with it.
enum LocalModelKind: String, Sendable {
    case text            // a text LLM
    case vision          // a VLM: text + images (MLXVLM knows its architecture)
    case unsupported     // an architecture this build cannot load (e.g. a speech or diffusion repo)
}

struct LocalModelInfo: Sendable, Hashable {
    let id: String           // Hugging Face repo id
    let dir: URL
    let bytes: Int64
    let modelType: String    // config.json model_type
    let kind: LocalModelKind
    /// Chat template accepts `enable_thinking` — the reasoning toggle is meaningful and the model emits
    /// `<think…>` traces that the UI can collapse.
    let thinkingCapable: Bool
    /// `text_config.max_position_embeddings`; nil when absent.
    let contextLength: Int?
    /// Bytes of K/V this model must **read per decoded token per context token** — i.e. KV bytes per
    /// token of context. This is the number that decides on-device decode speed, because at long context
    /// it dwarfs the weights:
    ///
    ///   Qwen3-0.6B: 28 layers x 2 (K,V) x 8 kv-heads x 128 head-dim x 2 bytes = 112 KB / context token
    ///   → at a 6.6k-token prompt that is ~740 MB read for EVERY generated token,
    ///     against 335 MB of weights. Total ~1.1 GB per token ⇒ ~51 tok/s at ~56 GB/s.
    ///
    /// ...which is why a short-prompt benchmark reads ~160 tok/s and a real turn reads ~40. Only layers
    /// that keep a growing attention cache count: a hybrid model's linear-attention (Gated DeltaNet)
    /// layers hold a constant-size state, so counting them would overstate its cost enormously.
    let kvBytesPerToken: Int
    /// Sampler recommendations from the model's own generation_config.json.
    let sampling: LocalSampling

    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
    var supportsVision: Bool { kind == .vision }
}

/// A model's own recommended decoder settings.
struct LocalSampling: Sendable, Hashable {
    var temperature: Float = 0.6
    var topP: Float = 1.0
    var topK: Int = 0
    var minP: Float = 0.0
    var repetitionPenalty: Float?

    /// [T-nabla-local-mlx-sampling] Why `topP` defaults to 1.0 here.
    ///
    /// MLX's `TopPSampler` implements nucleus filtering with `argSort` over the **entire vocabulary**
    /// plus a `putAlong` scatter — for Qwen3 that is 151,936 elements, for Qwen3.5 248,320 — executed
    /// once per generated token. Measured on this device, that is the difference between ~164 tok/s and
    /// ~50 tok/s on Qwen3-0.6B: the model itself is not slower, the sampler is. `applyTopK` uses an
    /// O(V) partition and `applyMinP` a single comparison, so either is dramatically cheaper. When a
    /// config asks for both we keep the cheap one.
    static func sanitized(temperature: Float, topP: Float, topK: Int, minP: Float,
                          repetitionPenalty: Float?) -> LocalSampling {
        var s = LocalSampling()
        s.temperature = temperature
        s.topK = topK
        s.minP = minP
        s.repetitionPenalty = repetitionPenalty
        // A large topP is a no-op anyway (nil internally); anything below 1 buys a full-vocab sort.
        s.topP = (topP > 0 && topP < 1 && topK == 0 && minP == 0) ? topP : 1.0
        return s
    }
}

enum LocalModelStore {
    /// Where the library lives when the user has not chosen somewhere else.
    static var defaultRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var r = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        // [T-nabla-local-mlx-backup] Excluded from iCloud backup: multi-GB model weights must not be
        // uploaded by the user's backup. Needs a var — setResourceValues is mutating.
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? r.setResourceValues(v)
        return r
    }

    /// [T-nabla-local-mlx-folder] The library folder, which the user can point anywhere the Files app
    /// can reach — iCloud Drive, an external drive, a network share — so models are not locked inside
    /// this app's container and do not have to be downloaded twice to be used by two apps.
    ///
    /// The choice is persisted as a **security-scoped bookmark**, the only reference to an outside
    /// folder that survives relaunch on iOS. Access is re-claimed on each lookup.
    static let folderBookmarkKey = "nabla.onDeviceModelsFolder"

    static var isUsingCustomFolder: Bool {
        UserDefaults.standard.data(forKey: folderBookmarkKey) != nil
    }

    static var root: URL {
        guard let data = UserDefaults.standard.data(forKey: folderBookmarkKey) else {
            return defaultRoot
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            useDefaultRoot()
            return defaultRoot
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    static func setRoot(_ url: URL) throws {
        _ = url.startAccessingSecurityScopedResource()
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: folderBookmarkKey)
    }

    static func useDefaultRoot() { UserDefaults.standard.removeObject(forKey: folderBookmarkKey) }

    static func dir(for id: String) -> URL {
        root.appendingPathComponent(id.replacingOccurrences(of: "/", with: "__"))
    }

    static func isModelDir(_ d: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: d.appendingPathComponent("config.json").path) else { return false }
        return ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).contains { $0.hasSuffix(".safetensors") }
    }

    /// Whether the library holds anything, cheaply.
    ///
    /// Read from view bodies that re-evaluate constantly, so the scan is cached briefly and invalidated
    /// explicitly when the library changes.
    private static var installedCache: (count: Int, at: Date)?

    static var hasInstalledModels: Bool {
        if let c = installedCache, Date().timeIntervalSince(c.at) < 3 { return c.count > 0 }
        let n = installed().count
        installedCache = (n, Date())
        return n > 0
    }

    static func invalidateInstalledCache() { installedCache = nil }

    static func installed() -> [LocalModelInfo] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter(isModelDir)
            .map(profile)
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Bytes needed to RUN this model at `contextTokens` of conversation.
    ///
    /// [T-nabla-local-mlx-fit] Not `weights x 1.35`. That first attempt scaled the weights, which both
    /// overstated small models and understated nothing — the real second term is the KV cache, and it is
    /// knowable from the config (`kvBytesPerToken`). Weighting weights instead produced a warning that a
    /// 5.14 GB model "needs 6.93 GB" when in truth it needs ~5.7 GB and would have fitted.
    /// How many tokens of context fit in `freeBytes` alongside this model, inverting `runCost`.
    ///
    /// Used to derive the output budget from the device rather than from a constant: the K/V of the tokens
    /// about to be generated has to fit next to the weights, and past that point the process is killed or
    /// crawls. Sharing the arithmetic with `runCost` keeps the admission check and the budget consistent.
    nonisolated static func affordableContextTokens(for info: LocalModelInfo, kvBits: Int,
                                                    freeBytes: Int64) -> Int {
        let kvScale = Double(kvBits) / 16.0
        let perToken = Double(info.kvBytesPerToken) * kvScale
        guard perToken > 0 else { return 0 }
        let working: Int64 = 320 * 1024 * 1024
        let room = Double(freeBytes - info.bytes - working)
        return room > 0 ? Int(room / perToken) : 0
    }

    nonisolated static func runCost(for info: LocalModelInfo, contextTokens: Int,
                                    kvBits: Int) -> Int64 {
        // Quantised K/V is stored at `kvBits` with a per-group scale; 16 -> 1.0 (full precision).
        let kvScale = Double(kvBits) / 16.0
        let kvBytes = Int64(Double(info.kvBytesPerToken) * kvScale * Double(max(0, contextTokens)))
        // Activations, the logit projection and the runtime's own buffers. Measured on this device:
        // a 0.6B model at 6.6k context needs roughly this much beyond weights + KV.
        let working: Int64 = 320 * 1024 * 1024
        return info.bytes + kvBytes + working
    }

    /// Weights on disk. SafeTensor shards only: configs and tokenizers are noise at this scale, and a
    /// directory can hold a stray README that would distort a memory estimate.
    nonisolated static func weightBytes(in d: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e where u.pathExtension == "safetensors" {
                total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    static func profile(_ d: URL) -> LocalModelInfo {
        func json(_ n: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent(n)))) as? [String: Any] ?? [:]
        }
        let cfg = json("config.json")
        let marker = json(".looplab.json")
        let id = marker["id"] as? String ?? d.lastPathComponent.replacingOccurrences(of: "__", with: "/")
        let modelType = (cfg["model_type"] as? String) ?? "?"
        let textCfg = (cfg["text_config"] as? [String: Any]) ?? cfg

        // A template that mentions enable_thinking is the template that can turn reasoning on. Read the
        // tokenizer config's inline template and the side-car .jinja alike — the two models in this
        // library use one each.
        var template = json("tokenizer_config.json")["chat_template"] as? String ?? ""
        template += (try? String(contentsOf: d.appendingPathComponent("chat_template.jinja"), encoding: .utf8)) ?? ""

        // vision_config, or the weights themselves, say this is a VLM. The type must also be one
        // MLXVLM knows how to build.
        let hasVisionConfig = cfg["vision_config"] != nil
            || FileManager.default.fileExists(atPath: d.appendingPathComponent("preprocessor_config.json").path)
        let isUnsupported = modelType.hasPrefix("whisper") || modelType.contains("stable_diffusion")
            || modelType.contains("flux")
        let kind: LocalModelKind = isUnsupported ? .unsupported
            : (hasVisionConfig && LocalModelStore.vlmTypes.contains(modelType)) ? .vision : .text

        var sampling = LocalSampling()
        let gen = json("generation_config.json")
        if !gen.isEmpty {
            // The trailing sampling block is what a chat template applies last; if the file carries a
            // flat set (no per-mode nesting) use it directly.
            let flat = (gen["temperature"] != nil || gen["top_p"] != nil || gen["top_k"] != nil)
                ? gen : [:]
            sampling = LocalSampling.sanitized(
                temperature: (flat["temperature"] as? NSNumber)?.floatValue ?? 0.6,
                topP: (flat["top_p"] as? NSNumber)?.floatValue ?? 1.0,
                topK: (flat["top_k"] as? NSNumber)?.intValue ?? 0,
                minP: (flat["min_p"] as? NSNumber)?.floatValue ?? 0,
                repetitionPenalty: (flat["repetition_penalty"] as? NSNumber)?.floatValue)
        } else {
            sampling = LocalSampling.sanitized(temperature: 0.6, topP: 1.0, topK: 20, minP: 0,
                                               repetitionPenalty: nil)
        }

        let ctx = (textCfg["max_position_embeddings"] as? NSNumber)?.intValue

        // KV geometry. Hybrid stacks declare `layer_types`; when they do, only the attention layers keep
        // a growing cache (Qwen3.5: 8 of 32 — the rest are linear attention with fixed state).
        let layers = (textCfg["num_hidden_layers"] as? NSNumber)?.intValue ?? 0
        let attentionLayers: Int = {
            if let types = textCfg["layer_types"] as? [String] {
                return types.filter { $0.contains("full_attention") || $0 == "attention" }.count
            }
            return layers
        }()
        let kvHeads = (textCfg["num_key_value_heads"] as? NSNumber)?.intValue ?? 0
        let headDim = (textCfg["head_dim"] as? NSNumber)?.intValue
            ?? ((textCfg["hidden_size"] as? NSNumber)?.intValue ?? 0)
                / max(1, (textCfg["num_attention_heads"] as? NSNumber)?.intValue ?? 1)
        // fp16 K and V while uncompressed — the baseline the estimate is compared against.
        let kvPerToken = attentionLayers * 2 * kvHeads * headDim * 2

        return LocalModelInfo(
            id: id, dir: d, bytes: weightBytes(in: d), modelType: modelType, kind: kind,
            thinkingCapable: template.contains("enable_thinking"),
            contextLength: ctx,
            kvBytesPerToken: kvPerToken,
            sampling: sampling)
    }

    /// Architectures MLXVLM can build. Anything else stays on the text path (and is honestly labelled).
    static let vlmTypes: Set<String> = [
        "qwen2_vl", "qwen2_5_vl", "qwen3_vl", "qwen3_vl_moe", "qwen3_5", "qwen3_5_moe",
        "paligemma", "idefics3", "gemma3", "gemma4", "smolvlm", "fastvlm", "llava_qwen2",
        "pixtral", "mistral3", "lfm2_vl", "glm_ocr", "muse_glimmer",
    ]

    /// Some checkpoints declare a tokenizer class the Swift loader does not know while being plain
    /// byte-level BPE underneath (OLMoE ships `GPTNeoXTokenizer`, which failed to load at all).
    static func normalizeTokenizer(in dir: URL) {
        let p = dir.appendingPathComponent("tokenizer_config.json")
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: p))) as? [String: Any],
              let cls = obj["tokenizer_class"] as? String,
              ["GPTNeoXTokenizer", "GPTNeoXTokenizerFast", "GPT2TokenizerFast"].contains(cls) else { return }
        obj["tokenizer_class"] = "PreTrainedTokenizer"
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) { try? d.write(to: p) }
    }

    /// Move a downloaded snapshot into the library.
    ///
    /// [T-nabla-local-mlx-symlinks] The Hugging Face hub cache does **not** store real files in the
    /// snapshot directory — it stores symlinks into a sibling `blobs/` directory:
    ///
    ///     models--org--name/blobs/<sha>                    <- the actual bytes
    ///     models--org--name/snapshots/<revision>/foo.bin   <- symlink -> ../../blobs/<sha>
    ///
    /// So moving the snapshot directory with a single `moveItem` keeps the symlinks but leaves the blobs
    /// behind, and every file dangles — which is exactly how the first download attempt failed, with the
    /// loader reporting `config.json` missing for a model that had downloaded fine. Walk the tree and
    /// move each *resolved* file instead.
    @discardableResult
    static func adopt(from src: URL, id: String) throws -> URL {
        let fm = FileManager.default
        let dest = dir(for: id)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let srcPath = src.standardizedFileURL.path
        guard let e = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw LocalModelError.unreadable(src)
        }
        var moved = 0
        for case let u as URL in e {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(srcPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rel.isEmpty else { continue }
            let target = dest.appendingPathComponent(rel)
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            let real = u.resolvingSymlinksInPath()
            do { try fm.moveItem(at: real, to: target) }
            catch { try fm.copyItem(at: real, to: target) }
            moved += 1
        }
        guard moved > 0 else { throw LocalModelError.unreadable(src) }
        var p = src
        for _ in 0..<4 {
            if p.lastPathComponent.hasPrefix("models--") { try? fm.removeItem(at: p); break }
            p = p.deletingLastPathComponent()
        }
        guard isModelDir(dest) else { throw LocalModelError.incomplete(dest) }
        let marker = try JSONSerialization.data(
            withJSONObject: ["id": id, "source": "huggingface",
                             "adopted": ISO8601DateFormatter().string(from: Date())],
            options: [.prettyPrinted])
        try? marker.write(to: dest.appendingPathComponent(".looplab.json"))
        invalidateInstalledCache()
        return dest
    }

    /// Delete a model from the library. Needed because a partial or unreadable download otherwise stays
    /// forever and cannot be cleared from the UI.
    static func remove(_ id: String) throws {
        let d = dir(for: id)
        if FileManager.default.fileExists(atPath: d.path) {
            try FileManager.default.removeItem(at: d)
        }
        invalidateInstalledCache()
    }
}

/// Failures the library itself can describe, so the settings page can say what actually went wrong
/// instead of surfacing a raw Cocoa error from deep inside the loader.
enum LocalModelError: LocalizedError {
    case unreadable(URL)
    case incomplete(URL)
    case notInstalled(String)
    case outOfMemory(needBytes: Int64, haveBytes: Int64, model: String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let u):
            return "Nothing could be read from the downloaded model at \(u.path)."
        case .incomplete(let u):
            return "The download at \(u.path) is incomplete — no config.json with weights beside it. Delete it and try again."
        case .notInstalled(let id):
            return "\(id) is not in the on-device library. Download it from Settings → Local Inference first."
        case .outOfMemory(let need, let have, let model):
            let f = ByteCountFormatter()
            return """
            Not enough memory for \(model). It needs about \(f.string(fromByteCount: need)) \
            (weights plus working room) but only \(f.string(fromByteCount: have)) is available. \
            Unload other models, or choose a smaller quantisation (a 4-bit build of the same model is \
            roughly half the size).
            """
        }
    }
}
