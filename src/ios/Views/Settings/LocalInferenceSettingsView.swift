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
//
// This page is also where the library is filled: the engine runs whatever sits in Documents/Models,
// which is a normal folder in Files, so a model can arrive by download here, by copy from another app
// (LoopLab keeps its models in the same relative place), or by AirDrop into Files.

@MainActor
final class LocalInferenceModel: ObservableObject {
    @Published var models: [LocalModelInfo] = []
    @Published var libraryPath: String = ""
    @Published var availableMemoryBytes: Int = 0
    @Published var memoryEntitlementGranted = false
    @Published var thermalState: String = "?"
    @Published var gpuName: String = "?"
    @Published var gpuWorkingSetBytes: UInt64 = 0
    @Published var appleIntelligenceStatus: String = "unknown"
    @Published var residentModel: String?
    @Published var busyModel: String?
    @Published var progress: Double?
    @Published var errorText: String?
    @Published var downloadField: String = ""

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    nonisolated func format(_ bytes: Int64) -> String { Self.byteFormatter.string(fromByteCount: bytes) }

    func refresh() {
        // The library listing comes from LocalModelStore, the same enumeration the engine and the
        // picker use — one source of truth, so the page cannot show a model the engine would reject.
        models = LocalModelStore.installed()
        libraryPath = LocalModelStore.root.path
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

        Task {
            let s = await LocalModelHost.shared.status()
            residentModel = s.resident ? s.modelId : nil
        }
    }

    // MARK: - Engine control

    func load(_ id: String) {
        guard busyModel == nil else { return }
        busyModel = id
        errorText = nil
        progress = models.contains(where: { $0.id == id }) ? nil : 0
        Task {
            do {
                _ = try await LocalModelHost.shared.load(id) { p in
                    Task { @MainActor in self.progress = p }
                }
                progress = nil
                busyModel = nil
                refresh()
            } catch {
                // Honest failure: a model that will not fit (or will not parse) must say so here
                // rather than surface later as an agent turn that simply never produces tokens.
                errorText = "\(error)"
                progress = nil
                busyModel = nil
            }
        }
    }

    func downloadAndLoad(_ raw: String) {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, busyModel == nil else { return }
        downloadField = ""
        load(id)
    }

    func unload() {
        Task {
            await LocalModelHost.shared.unload()
            refresh()
        }
    }

    // MARK: - Device facts

    /// Memory this process may actually use. The entitlement raises it from ~3.25 GB to ~6 GB on an
    /// iPhone 17 Pro Max, which measured as a ~3x decode-speed difference.
    nonisolated static func availableMemory() -> Int { os_proc_available_memory() }

    /// Whether the signed build carries `com.apple.developer.kernel.increased-memory-limit`.
    /// Read from the embedded provisioning profile, not assumed: the value depends on what the signer
    /// granted, which is exactly what went wrong for the app group.
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
                        Text(AppLocalized("Models live in a folder you can open in Files. Drop a folder in, or download one below."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(model.models, id: \.id) { record in
                        modelRow(record)
                    }
                }
            } header: {
                Text(AppLocalized("On-device models"))
            } footer: {
                Text(model.libraryPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField(AppLocalized("org/model-name"), text: $model.downloadField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.callout.monospaced())
                    Button(AppLocalized("Get")) {
                        model.downloadAndLoad(model.downloadField)
                    }
                    .disabled(model.downloadField.trimmingCharacters(in: .whitespaces).isEmpty || model.busyModel != nil)
                }
                if let id = model.busyModel {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.progress == nil
                             ? AppLocalized("Loading ") + id
                             : AppLocalized("Downloading ") + id)
                            .font(.caption)
                        if let p = model.progress {
                            ProgressView(value: p)
                        } else {
                            ProgressView()
                        }
                    }
                }
                if let e = model.errorText {
                    Text(e)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                }
            } header: {
                Text(AppLocalized("Add a model"))
            } footer: {
                Text(AppLocalized("Any MLX-format model from Hugging Face. It is downloaded once, moved into the folder above, and then runs offline."))
                    .font(.caption)
            }

            Section(AppLocalized("Engines")) {
                LabeledContent(AppLocalized("On-device (MLX)")) {
                    if let r = model.residentModel {
                        Text(AppLocalized("running ") + r.split(separator: "/").last!)
                            .foregroundStyle(.green)
                    } else {
                        Text(model.models.isEmpty ? AppLocalized("no models") : AppLocalized("ready"))
                            .foregroundStyle(model.models.isEmpty ? .secondary : .green)
                    }
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
                    Text(model.format(Int64(clamping: model.gpuWorkingSetBytes))).font(.callout.monospaced())
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

    @ViewBuilder
    private func modelRow(_ record: LocalModelInfo) -> some View {
        let isResident = model.residentModel == record.id
        let isBusy = model.busyModel == record.id
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.name).font(.subheadline).fontWeight(.medium)
                if isResident {
                    Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green)
                }
                Spacer()
                Text(model.format(record.bytes))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                tag(record.modelType)
                if record.thinkingCapable { tag(AppLocalized("can think")) }
                Spacer()
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else if isResident {
                    Button(AppLocalized("Unload")) { model.unload() }
                        .font(.caption).buttonStyle(.bordered)
                } else {
                    Button(AppLocalized("Load")) { model.load(record.id) }
                        .font(.caption).buttonStyle(.bordered)
                        .disabled(model.busyModel != nil)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 4))
    }
}
