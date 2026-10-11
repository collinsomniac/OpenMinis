import SwiftUI
import Metal

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Local Inference settings
//
// [T-nabla-local-inference] The app's first settings area for models that are *not* behind a network
// provider. Nothing here talks to a cloud service, needs a credential, or writes to
// ProviderConfigStore — the engine is reached through a sentinel provider id instead
// (see `SystemVoiceProvider` for the established pattern, and docs/OPENMINIS-ANALYSIS.md §4b).
//
// Why a settings page rather than a provider row: on-device models are artefacts on disk with sizes,
// load costs and a fixed memory budget. A credential form cannot express "2.3 GB, currently resident,
// 27 tok/s". Everything the rest of the app measures is about tokens and context; nothing was about
// the hardware, and on a phone the hardware is the binding constraint.

/// One model file set found in the on-device library.
struct LocalModelRecord: Identifiable, Hashable {
    let id: String            // Hugging Face repo id, or a folder name for an imported model
    let directory: URL
    let bytes: Int64
    let modelType: String
    let thinkingCapable: Bool

    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
}

@MainActor
final class LocalInferenceModel: ObservableObject {
    @Published var models: [LocalModelRecord] = []
    @Published var libraryPath: String = ""
    @Published var availableMemoryBytes: Int = 0
    @Published var memoryEntitlementGranted = false
    @Published var thermalState: String = "?"
    @Published var gpuName: String = "?"
    @Published var gpuWorkingSetBytes: Int = 0
    @Published var appleIntelligenceStatus: String = "unknown"
    @Published var isScanning = false

    private let fm = FileManager.default

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    func format(_ bytes: Int64) -> String { Self.byteFormatter.string(fromByteCount: bytes) }

    /// Where on-device models live. Deliberately a plain folder the user can see: it is inside the
    /// app container's Documents directory, so it appears in Files › On My iPhone › Nabla, and a
    /// model can be dropped in or removed without this app's help.
    var libraryURL: URL {
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func refresh() {
        isScanning = true
        defer { isScanning = false }

        libraryPath = libraryURL.path
        availableMemoryBytes = Self.availableMemory()
        memoryEntitlementGranted = Self.hasIncreasedMemoryLimit()

        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalState = "nominal"
        case .fair: thermalState = "fair"
        case .serious: thermalState = "serious"
        case .critical: thermalState = "critical"
        @unknown default: thermalState = "unknown"
        }

        if let device = MTLCreateSystemDefaultDevice() {
            gpuName = device.name
            gpuWorkingSetBytes = device.recommendedMaxWorkingSetSize
        }

        appleIntelligenceStatus = Self.appleIntelligenceAvailability()
        models = Self.scan(libraryURL)
    }

    // MARK: - Scanning

    /// A directory counts as a model when it has a config.json and at least one .safetensors file —
    /// the same rule the loader uses, so the listing cannot claim a model the engine would reject.
    nonisolated static func isModelDirectory(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) else { return false }
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.contains { $0.hasSuffix(".safetensors") }
    }

    nonisolated static func scan(_ root: URL) -> [LocalModelRecord] {
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return subs.filter { isModelDirectory($0) }.map { dir in
            func json(_ name: String) -> [String: Any] {
                guard let d = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return [:] }
                return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
            }
            let marker = json(".looplab.json")
            let id = marker["id"] as? String
                ?? dir.lastPathComponent.replacingOccurrences(of: "__", with: "/")
            var template = json("tokenizer_config.json")["chat_template"] as? String ?? ""
            if let jinja = try? String(contentsOf: dir.appendingPathComponent("chat_template.jinja"), encoding: .utf8) {
                template += jinja
            }
            var total: Int64 = 0
            if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let u as URL in e {
                    total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            return LocalModelRecord(id: id, directory: dir, bytes: total,
                                    modelType: json("config.json")["model_type"] as? String ?? "?",
                                    thinkingCapable: template.contains("enable_thinking"))
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Device facts

    /// Memory this process may actually use. The entitlement increases it from ~3.25 GB to ~6 GB on
    /// an iPhone 17 Pro Max, which measured as a ~3x decode-speed difference (see FINDINGS-R3).
    nonisolated static func availableMemory() -> Int { os_proc_available_memory() }

    /// Whether the signed build carries `com.apple.developer.kernel.increased-memory-limit`.
    /// Read from the embedded provisioning profile, not assumed: the value depends on what the
    /// signer granted, which is exactly what failed for the app group.
    nonisolated static func hasIncreasedMemoryLimit() -> Bool {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<plist"), let end = text.range(of: "</plist>")
        else { return false }
        let plistData = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let ents = plist["Entitlements"] as? [String: Any] else { return false }
        return (ents["com.apple.developer.kernel.increased-memory-limit"] as? Bool) == true
    }

    /// Apple's on-device model (Apple Intelligence). Not a network provider and not something this
    /// app can download; it either exists on the device and is enabled, or it does not.
    nonisolated static func appleIntelligenceAvailability() -> String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(let reason): return "unavailable — \(Self.describe(reason))"
            @unknown default: return "unknown"
            }
        }
        return "requires iOS 26"
        #else
        return "framework not present in this SDK"
        #endif
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    nonisolated static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "device not eligible"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is off in Settings"
        case .modelNotReady: return "model not ready (downloading or warming up)"
        @unknown default: return "unknown reason"
        }
    }
    #endif
}

struct LocalInferenceSettingsView: View {
    @StateObject private var model = LocalInferenceModel()

    var body: some View {
        List {
            Section {
                if model.models.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AppLocalized("No on-device models yet"))
                            .font(.subheadline).fontWeight(.medium)
                        Text(AppLocalized("Models live in a folder you can open in Files. Drop a folder in, or download one here once the engine lands."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(model.models) { record in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(record.name).font(.subheadline).fontWeight(.medium)
                                Spacer()
                                Text(model.format(record.bytes))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                tag(record.modelType)
                                if record.thinkingCapable { tag(AppLocalized("can think")) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text(AppLocalized("On-device models"))
                    Spacer()
                    if model.isScanning { ProgressView().controlSize(.mini) }
                }
            } footer: {
                Text(model.libraryPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Section(AppLocalized("Engines")) {
                LabeledContent(AppLocalized("On-device (MLX)")) {
                    Text(AppLocalized("not linked yet")).foregroundStyle(.secondary)
                }
                LabeledContent(AppLocalized("Apple Intelligence")) {
                    Text(model.appleIntelligenceStatus)
                        .foregroundStyle(model.appleIntelligenceStatus == "available" ? .green : .secondary)
                }
            }

            Section(AppLocalized("Hardware")) {
                LabeledContent(AppLocalized("Memory available")) {
                    Text(model.format(Int64(model.availableMemoryBytes))).font(.callout.monospaced())
                }
                LabeledContent(AppLocalized("Increased memory limit")) {
                    Text(model.memoryEntitlementGranted
                         ? AppLocalized("granted")
                         : AppLocalized("not granted — expect ~3.3 GB"))
                        .foregroundStyle(model.memoryEntitlementGranted ? .green : .orange)
                }
                LabeledContent(AppLocalized("GPU")) {
                    Text(model.gpuName).font(.callout)
                }
                LabeledContent(AppLocalized("GPU working set")) {
                    Text(model.format(Int64(model.gpuWorkingSetBytes))).font(.callout.monospaced())
                }
                LabeledContent(AppLocalized("Thermal state")) {
                    Text(model.thermalState)
                        .foregroundStyle(model.thermalState == "nominal" ? .green : .orange)
                }
            }

            Section {
                Text(AppLocalized("On-device models run entirely on this device. They use the GPU, count against the memory shown above, and slow down when the phone is warm — expect roughly 20% less throughput on a long run."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(AppLocalized("Local Inference"))
        .navigationBarTitleDisplayMode(.inline)
        .task { model.refresh() }
        .refreshable { model.refresh() }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
    }
}
