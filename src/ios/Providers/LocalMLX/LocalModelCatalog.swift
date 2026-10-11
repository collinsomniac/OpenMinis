import Foundation

// Ask Hugging Face what a repository contains *before* downloading several gigabytes of it.
//
// [T-nabla-local-inference-inspect] The first version of the add-model flow took a repo id and went
// straight to downloading. That is the wrong shape for models: the user cannot tell a 0.35 GB
// quantisation from a 16 GB one, cannot tell whether the repo is an MLX conversion at all, and gets no
// chance to notice a typo in the id. One GET to the Hub's model API returns the file list and the size
// of every file, which is everything needed to show a real confirmation.
//
// Deliberately no credential: these are public repositories, and adding a token would mean storing one.
// Gated repositories fail with a clear message instead (see `LocalModelError.unauthorised`).

struct LocalModelFile: Sendable, Hashable {
    let name: String
    let size: Int64
}

/// Everything known about a repository before it is downloaded.
struct LocalModelInspection: Sendable, Identifiable {
    let id: String                  // repo id, "org/name"
    /// FULL commit sha. Needed twice over: the resolve URL must pin the exact revision (a moved branch
    /// would otherwise change what a half-finished download is fetching), and the sheet shows a prefix.
    let revision: String?
    let files: [LocalModelFile]
    let totalBytes: Int64
    let weightBytes: Int64
    let hasConfig: Bool
    let hasWeights: Bool

    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
    var shortRevision: String? { revision.map { String($0.prefix(12)) } }

    /// Whether the repository looks like a loadable MLX-format model: a `config.json` plus at least one
    /// `.safetensors` shard beside it. A repo can be perfectly valid for the Hub and still be unusable
    /// here (GGUF, PyTorch `.bin`, a LoRA adapter).
    var isLoadable: Bool { hasConfig && hasWeights }

    var warning: String? {
        if !hasWeights {
            return "No .safetensors weights in this repository — it is probably a GGUF, PyTorch, or adapter repo. The on-device engine needs the MLX (safetensors) conversion."
        }
        if !hasConfig {
            return "No config.json at the top level, so the engine cannot identify the architecture."
        }
        return nil
    }
}

enum LocalModelCatalogError: LocalizedError {
    case notFound(String)
    case unauthorised(String)
    case badResponse(String)
    case emptyRepository

    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "“\(id)” was not found on Hugging Face. Check the spelling — ids are case-sensitive, and look like org/model-name."
        case .unauthorised(let id):
            return "“\(id)” requires accepting a licence before it can be downloaded, and this app has no Hugging Face token configured."
        case .badResponse(let detail):
            return "Hugging Face returned an unexpected response: \(detail)"
        case .emptyRepository:
            return "That repository has no downloadable files."
        }
    }
}

enum LocalModelCatalog {
    /// Files that can never be needed to run a model here. Skipping them keeps a download honest about
    /// its size (a repo can ship several quantisations) and avoids pulling duplicate weight formats.
    private static let skipExtensions: Set<String> = [
        "gguf", "pth", "bin", "h5", "msgpack", "onnx", "tflite", "mlmodel", "ot", "zip", "tar", "gz",
    ]
    private static let skipNames: Set<String> = [".gitattributes", ".gitignore", "README.md"]

    /// Accept anything the user may reasonably paste: a bare id, a model URL, or a URL with /tree/main.
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"] {
            if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        }
        for marker in ["/tree/", "/blob/", "/resolve/", "?"] {
            if let r = s.range(of: marker) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func inspect(_ rawRepo: String) async throws -> LocalModelInspection {
        let repo = normalize(rawRepo)
        guard !repo.isEmpty, repo.contains("/") else {
            throw LocalModelCatalogError.notFound(rawRepo)
        }
        guard let encoded = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://huggingface.co/api/models/\(encoded)?blobs=true") else {
            throw LocalModelCatalogError.notFound(repo)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A browser-style UA: the Hub answers anonymous API calls that look like an app, but a bare
        // URLSession UA has been refused in the past for some model repos.
        request.setValue("Nabla/1.0 (iOS; on-device inference)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LocalModelCatalogError.badResponse(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 401, 403: throw LocalModelCatalogError.unauthorised(repo)
            case 404: throw LocalModelCatalogError.notFound(repo)
            default: throw LocalModelCatalogError.badResponse("HTTP \(http.statusCode)")
            }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = obj["siblings"] as? [[String: Any]] else {
            throw LocalModelCatalogError.badResponse("no file list in the response")
        }

        var files: [LocalModelFile] = []
        for s in siblings {
            guard let name = s["rfilename"] as? String else { continue }
            if skipNames.contains(name) { continue }
            let ext = (name as NSString).pathExtension.lowercased()
            if skipExtensions.contains(ext) { continue }
            // Nested paths (e.g. an "original/" folder holding the fp16 source) are not needed and can
            // be enormous; the runtime reads the top level.
            if name.contains("/") { continue }
            let size = (s["size"] as? NSNumber)?.int64Value
                ?? ((s["lfs"] as? [String: Any])?["size"] as? NSNumber)?.int64Value
                ?? 0
            files.append(LocalModelFile(name: name, size: size))
        }
        guard !files.isEmpty else { throw LocalModelCatalogError.emptyRepository }

        let hasConfig = files.contains { $0.name == "config.json" }
        let weights = files.filter { $0.name.hasSuffix(".safetensors") }
        return LocalModelInspection(
            id: repo,
            revision: obj["sha"] as? String,
            files: files.sorted { $0.size > $1.size },
            totalBytes: files.reduce(0) { $0 + $1.size },
            weightBytes: weights.reduce(0) { $0 + $1.size },
            hasConfig: hasConfig,
            hasWeights: !weights.isEmpty
        )
    }
}
