import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

// LocalMLX — run the agent on the phone's GPU.
//
// One model is resident at a time (the GPU has one ~6 GB budget). Models live in the on-device library
// (Documents/Models, visible in the Files app). The provider keeps a live ChatSession so an agent turn
// only prefills tokens it has not seen — the agent loop re-sends the whole transcript every turn, so
// without this each turn re-reads everything.
//
// [T-nabla-local-mlx-shadowing] `ChatSession` is **module-qualified everywhere in this file**. The app
// declares its own `ChatSession` (Agent/Chat/ChatStore.swift:42, the chat-session *record*, Codable),
// and a same-module declaration shadows an imported one, so an unqualified `ChatSession` resolves to
// that struct — which produced "extra arguments in call" (the compiler fell back to `init(from:
// Decoder)`) and "has no member 'streamDetails'". Qualifying is required, not stylistic.
//
// [T-nabla-local-mlx-cache] Cache policy, after ninfer's typed resume points and Strata's
// message-boundary cache — **restricted to what mlx-swift-lm 3.32.3 actually offers**. The first draft
// of this file called `ChatSession.fork(...)`, which does not exist in 3.32.3 (nor in our fork); a
// session owns exactly one cache and exposes no copy. So instead of forking, the host keeps the live
// session *and* a record of the transcript it has already processed, and reuses the session only when
// the incoming request continues that conversation by exactly one turn. Anything else — an edited
// message, a retry, a rewritten tool result, a switched model or thinking mode — rebuilds the session
// from the prior history via the `history:` initialiser ("prompt re-hydration"). That is correct in
// every case and still gives turn 2+ the cheap path, which is where the agent loop lives.
//
// Ported from LoopLab (github.com/collinsomniac/looplab). Needs the
// com.apple.developer.kernel.increased-memory-limit entitlement: ~6 GB usable instead of ~3.25 GB,
// which measured as a ~3x decode-speed difference on an iPhone 17 Pro Max.

// MARK: - Library

struct LocalModelInfo: Sendable, Hashable {
    let id: String           // Hugging Face repo id
    let dir: URL
    let bytes: Int64
    let modelType: String
    let thinkingCapable: Bool
    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
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
    /// The choice is persisted as a **security-scoped bookmark**, which is the only form of reference
    /// to an outside folder that survives relaunch on iOS. Access is claimed on each lookup; the claim
    /// is what the picker granted, and it has to be re-asserted when the app is relaunched.
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
            // The folder was deleted or the bookmark invalidated (e.g. the app was restored from a
            // backup). Fall back rather than presenting an unusable library.
            useDefaultRoot()
            return defaultRoot
        }
        _ = url.startAccessingSecurityScopedResource()
        return url
    }

    /// Point the library at `url` (from the Files folder picker).
    static func setRoot(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: folderBookmarkKey)
        if !scoped { /* the picker grants access without this returning true for some providers */ }
    }

    static func useDefaultRoot() {
        UserDefaults.standard.removeObject(forKey: folderBookmarkKey)
    }

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
    /// Read from view bodies that re-evaluate constantly (every "is there a provider?" check), so the
    /// directory scan is cached briefly and invalidated explicitly when the library changes. A scan per
    /// render would be a needless syscall storm on the main thread.
    private static var installedCache: (count: Int, at: Date)?

    static var hasInstalledModels: Bool {
        if let c = installedCache, Date().timeIntervalSince(c.at) < 3 { return c.count > 0 }
        let n = installed().count
        installedCache = (n, Date())
        return n > 0
    }

    static func invalidateInstalledCache() { installedCache = nil }

    static func installed() -> [LocalModelInfo] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter(isModelDir)
            .map(profile)
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func profile(_ d: URL) -> LocalModelInfo {
        func json(_ n: String) -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent(n)))) as? [String: Any] ?? [:]
        }
        let marker = json(".looplab.json")
        let id = marker["id"] as? String ?? d.lastPathComponent.replacingOccurrences(of: "__", with: "/")
        var template = json("tokenizer_config.json")["chat_template"] as? String ?? ""
        template += (try? String(contentsOf: d.appendingPathComponent("chat_template.jinja"), encoding: .utf8)) ?? ""
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return LocalModelInfo(id: id, dir: d, bytes: total,
                              modelType: json("config.json")["model_type"] as? String ?? "?",
                              thinkingCapable: template.contains("enable_thinking"))
    }

    /// Move a downloaded snapshot into the library.
    ///
    /// [T-nabla-local-mlx-symlinks] The Hugging Face hub cache does **not** store real files in the
    /// snapshot directory — it stores symlinks into a sibling `blobs/` directory:
    ///
    ///     models--org--name/blobs/<sha>                    <- the actual bytes
    ///     models--org--name/snapshots/<revision>/foo.bin   <- symlink -> ../../blobs/<sha>
    ///
    /// So moving the snapshot directory with a single `moveItem` keeps the symlinks but leaves the
    /// blobs behind, and every file dangles. That is not a hypothetical: it is exactly how the first
    /// download attempt failed, with the loader reporting `config.json` missing in the adopted folder
    /// (NSFileReadNoSuchFileError) for a model that had downloaded perfectly well.
    ///
    /// The fix walks the tree and moves each *resolved* file, so what lands in the library is real
    /// bytes. Copied from LoopLab's `ModelStore.adopt`, which is known good on this device.
    @discardableResult
    static func adopt(from src: URL, id: String) throws -> URL {
        let fm = FileManager.default
        let dest = dir(for: id)
        // A previous interrupted adopt must not leave a half-written model behind.
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
            let real = u.resolvingSymlinksInPath()          // <-- materialise the blob
            do { try fm.moveItem(at: real, to: target) }
            catch { try fm.copyItem(at: real, to: target) }
            moved += 1
        }
        guard moved > 0 else { throw LocalModelError.unreadable(src) }
        // Remove the Hub cache repo directory the snapshot lived in, now that its files are moved.
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
        return dest
    }

    /// Delete a model from the library. Needed because a partial or unreadable download otherwise
    /// stays forever and cannot be cleared from the UI.
    static func remove(_ id: String) throws {
        let d = dir(for: id)
        if FileManager.default.fileExists(atPath: d.path) {
            try FileManager.default.removeItem(at: d)
        }
    }

    /// Some checkpoints declare a tokenizer class the Swift loader does not know while being plain
    /// byte-level BPE underneath (OLMoE ships `GPTNeoXTokenizer`, which failed to load at all).
    /// Rewriting the declared class is what unblocked that model in LoopLab; kept identical here.
    static func normalizeTokenizer(in dir: URL) {
        let p = dir.appendingPathComponent("tokenizer_config.json")
        guard var obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: p))) as? [String: Any],
              let cls = obj["tokenizer_class"] as? String,
              ["GPTNeoXTokenizer", "GPTNeoXTokenizerFast", "GPT2TokenizerFast"].contains(cls) else { return }
        obj["tokenizer_class"] = "PreTrainedTokenizer"
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) { try? d.write(to: p) }
    }
}

// MARK: - Engine

/// Owns the resident model and the live chat session. An actor, so the GPU is never driven by two
/// requests at once — and so none of this runs on the main actor, which the app leans on heavily
/// (704 `@MainActor` against 19 `actor`; GPU work must not join that crowd).
actor LocalModelHost {
    static let shared = LocalModelHost()

    private(set) var modelId: String?
    private var container: ModelContainer?
    private var session: MLXLMCommon.ChatSession?
    private var sessionKey: String?
    /// The transcript the live session has already consumed, *including* the reply it generated.
    private var consumed: [(role: String, text: String)] = []

    func load(_ id: String, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> ModelContainer {
        if modelId == id, let c = container { return c }
        unload()
        Memory.cacheLimit = 512 * 1024 * 1024
        let dir: URL
        if LocalModelStore.isModelDir(LocalModelStore.dir(for: id)) {
            dir = LocalModelStore.dir(for: id)
        } else {
            let resolved = try await resolve(configuration: ModelConfiguration(id: id),
                                             from: #hubDownloader(), useLatest: false) { p in
                onProgress?(p.fractionCompleted)
            }
            dir = (try? LocalModelStore.adopt(from: resolved.modelDirectory, id: id)) ?? resolved.modelDirectory
        }
        LocalModelStore.normalizeTokenizer(in: dir)
        let c = try await LLMModelFactory.shared.loadContainer(from: dir, using: #huggingFaceTokenizerLoader())
        container = c
        modelId = id
        return c
    }

    func unload() {
        container = nil; session = nil; sessionKey = nil; consumed = []; modelId = nil
        Memory.clearCache()
    }

    /// Stream one assistant turn. `history` is the full transcript as (role, text).
    func stream(modelId id: String, system: String?, history: [(role: String, text: String)],
                maxTokens: Int, temperature: Float, thinking: Bool,
                onEvent: @escaping @Sendable (LocalEvent) -> Void) async throws {
        let c = try await load(id)
        let key = "\(id)|\(system ?? "")|\(thinking)"
        var params = GenerateParameters(maxTokens: maxTokens, temperature: temperature)
        params.topP = 0.95

        let prior = Array(history.dropLast())
        let last = history.last ?? (role: "user", text: "")
        let lastMessage: MLXLMCommon.Chat.Message = last.role == "assistant" ? .assistant(last.text) : .user(last.text)

        // Reuse the live session only when this request continues exactly the conversation it holds.
        let reuse = session != nil && sessionKey == key && Self.sameTranscript(consumed, prior)
        if sessionKey != key { session = nil; consumed = [] }

        let s: MLXLMCommon.ChatSession
        let source: String
        if reuse, let live = session {
            s = live; source = "reused"
        } else {
            s = MLXLMCommon.ChatSession(c, instructions: system,
                            history: prior.map { $0.role == "assistant" ? .assistant($0.text) : .user($0.text) },
                            generateParameters: params,
                            additionalContext: ["enable_thinking": thinking])
            session = s; source = "cold"
        }
        sessionKey = key
        s.generateParameters = params
        let cached = (try? await s.cacheStatus())?.processedTokenCount ?? 0
        onEvent(.cache(reused: source == "reused", cachedMessages: cached))

        var out = ""
        var inThink = false
        for try await g in s.streamDetails(to: [lastMessage]) {
            if let chunk = g.chunk {
                out += chunk
                var rest = chunk
                while !rest.isEmpty {
                    if inThink {
                        if let r = rest.range(of: "</think>") {
                            onEvent(.thinking(String(rest[..<r.lowerBound])))
                            rest = String(rest[r.upperBound...]); inThink = false
                        } else { onEvent(.thinking(rest)); rest = "" }
                    } else {
                        if let r = rest.range(of: " thinking") {
                            let before = String(rest[..<r.lowerBound])
                            if !before.isEmpty { onEvent(.text(before)) }
                            rest = String(rest[r.upperBound...]); inThink = true
                        } else { onEvent(.text(rest)); rest = "" }
                    }
                }
            }
            if let info = g.info {
                onEvent(.usage(input: info.promptTokenCount, output: info.generationTokenCount,
                               tokensPerSecond: info.tokensPerSecond))
            }
        }
        // The session now holds the prompt and this reply; the next turn must extend exactly this.
        consumed = history + [(role: "assistant", text: out)]
        onEvent(.done(maxTokensHit: false))
    }

    /// Transcript comparison for the reuse decision. The generated text is recorded raw (thinking
    /// tags included) but callers may send the reply back with its thinking block stripped, so
    /// assistant turns are compared after removing ` thinking…</think>`. Anything else comparing
    /// unequal means a rebuild — slower, never wrong.
    private static func sameTranscript(_ a: [(role: String, text: String)],
                                       _ b: [(role: String, text: String)]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            if x.role != y.role { return false }
            if x.role == "assistant" {
                if stripThinking(x.text) != stripThinking(y.text) { return false }
            } else if x.text != y.text { return false }
        }
        return true
    }

    private static func stripThinking(_ s: String) -> String {
        var out = s
        while let a = out.range(of: " thinking"), let b = out.range(of: "</think>", range: a.upperBound..<out.endIndex) {
            out.removeSubrange(a.lowerBound..<b.upperBound)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Introspection (used by the Local Inference settings page)

    func status() -> LocalHostStatus {
        LocalHostStatus(modelId: modelId, resident: container != nil,
                        cacheLimitMB: Memory.cacheLimit / (1024 * 1024))
    }
}

/// Failures the library itself can describe, so the settings page can say what actually went wrong
/// instead of surfacing a raw Cocoa error from deep inside the loader.
enum LocalModelError: LocalizedError {
    case unreadable(URL)
    case incomplete(URL)

    var errorDescription: String? {
        switch self {
        case .unreadable(let u):
            return "Nothing could be read from the downloaded model at \(u.path)."
        case .incomplete(let u):
            return "The download at \(u.path) is incomplete — no config.json with weights beside it. Delete it and try again."
        }
    }
}

/// What the engine is currently holding, for the settings page. A typed value rather than a
/// dictionary so the UI cannot silently read a key the engine stopped writing.
struct LocalHostStatus: Sendable {
    var modelId: String?
    var resident: Bool
    var cacheLimitMB: Int
    var occupied: Bool { resident }
}

enum LocalEvent: Sendable {
    case cache(reused: Bool, cachedMessages: Int)
    case text(String)
    case thinking(String)
    case usage(input: Int, output: Int, tokensPerSecond: Double)
    case done(maxTokensHit: Bool)
}
