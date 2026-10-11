import SwiftUI
import Metal
import UniformTypeIdentifiers

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
// Adding a model is deliberately two steps: ask the Hub what the repository actually contains, show
// that, and only then download. See LocalModelCatalog for why.

@MainActor
final class LocalInferenceModel: ObservableObject {
    @Published var models: [LocalModelInfo] = []
    @Published var libraryPath: String = ""
    @Published var usingCustomFolder = false
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
    @Published var freeBytes: Int64 = 0
    // add-model flow
    @Published var inspecting = false
    @Published var inspection: LocalModelInspection?
    @Published var inspectError: String?
    // folder picker
    @Published var showingFolderPicker = false

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    nonisolated func format(_ bytes: Int64) -> String { Self.byteFormatter.string(fromByteCount: bytes) }

    func refresh() {
        // The rest of the app gates on "is anything installed" through a short-lived cache, so a change
        // here must invalidate it — otherwise the provider screens keep showing the previous answer.
        LocalModelStore.invalidateInstalledCache()
        models = LocalModelStore.installed()
        // [T-nabla-local-mlx-provider] The on-device provider's model list IS the folder. Re-read it
        // whenever the library may have changed (download, delete, folder move), through the same
        // refresh path a vendor's /models fetch uses, so the picker never offers a model that is gone.
        let store = ProviderConfigStore.shared
        for instance in store.instances where instance.providerType == .localMLX {
            Task { await store.refreshModels(for: instance) }
        }
        libraryPath = LocalModelStore.root.path
        usingCustomFolder = LocalModelStore.isUsingCustomFolder
        availableMemoryBytes = Self.availableMemory()
        memoryEntitlementGranted = Self.hasIncreasedMemoryLimit()
        freeBytes = Self.freeSpace(at: LocalModelStore.root)

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

    // MARK: - Add a model (check, then confirm, then download)

    func beginAdd(_ raw: String) {
        let repo = LocalModelCatalog.normalize(raw)
        guard !repo.isEmpty, !inspecting else { return }
        inspecting = true
        inspectError = nil
        downloadField = ""
        Task {
            do {
                let result = try await LocalModelCatalog.inspect(repo)
                inspection = result
            } catch {
                inspectError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            inspecting = false
        }
    }

    /// Called when the user confirms the sheet. The download itself goes through the MLX loader, which
    /// fetches into the Hub cache; `adopt` then materialises the files into the library folder.
    func confirmDownload(_ id: String) {
        inspection = nil
        load(id)
    }

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
                errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                progress = nil
                busyModel = nil
                // A failed load can leave a partial folder behind; clear it so the model can be retried
                // rather than looking installed while being unusable.
                try? LocalModelStore.remove(id)
                refresh()
            }
        }
    }

    func unload() {
        Task {
            await LocalModelHost.shared.unload()
            refresh()
        }
    }

    func delete(_ id: String) {
        Task {
            // Unload first and WAIT: deleting the files under a resident model would pull the weights
            // out from under the GPU mid-graph.
            if residentModel == id { await LocalModelHost.shared.unload() }
            try? LocalModelStore.remove(id)
            refresh()
        }
    }

    // MARK: - Folder

    func chooseFolder(_ url: URL) {
        do {
            try LocalModelStore.setRoot(url)
        } catch {
            errorText = "Could not use that folder: \(error.localizedDescription)"
        }
        refresh()
    }

    func useAppFolder() {
        LocalModelStore.useDefaultRoot()
        refresh()
    }

    // MARK: - Device facts

    nonisolated static func freeSpace(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

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

    /// Apple's on-device model (Apple Intelligence). Not a network provider and not something this app
    /// can download; it either exists on the device and is enabled, or it does not.
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
            modelsSection
            addSection
            storageSection
            enginesSection
            hardwareSection
            footnoteSection
        }
        .navigationTitle(AppLocalized("Local Inference"))
        .navigationBarTitleDisplayMode(.inline)
        .task { model.refresh() }
        .refreshable { model.refresh() }
        .fileImporter(isPresented: $model.showingFolderPicker,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            // A user-picked folder is outside the sandbox, so it arrives security-scoped; the store
            // turns it into a bookmark that survives relaunch.
            if case .success(let urls) = result, let url = urls.first {
                model.chooseFolder(url)
            }
        }
        .sheet(item: $model.inspection) { inspection in
            LocalModelConfirmView(inspection: inspection,
                                  freeBytes: model.freeBytes,
                                  format: model.format) { confirmed in
                if confirmed { model.confirmDownload(inspection.id) } else { model.inspection = nil }
            }
        }
    }

    // MARK: - Sections

    private var modelsSection: some View {
        Section {
            if model.models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppLocalized("No on-device models yet"))
                        .font(.subheadline).fontWeight(.medium)
                    Text(AppLocalized("Add one below, or drop a model folder into the library from Files."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(model.models, id: \.id) { record in
                    modelRow(record)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { model.delete(record.id) } label: {
                                Label(AppLocalized("Delete"), systemImage: "trash")
                            }
                        }
                }
            }
        } header: {
            Text(AppLocalized("On-device models"))
        }
    }

    private var addSection: some View {
        Section {
            HStack {
                TextField(AppLocalized("org/model-name"), text: $model.downloadField)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .onSubmit { model.beginAdd(model.downloadField) }
                Button(AppLocalized("Check")) { model.beginAdd(model.downloadField) }
                    .disabled(model.downloadField.trimmingCharacters(in: .whitespaces).isEmpty || model.inspecting)
            }
            if model.inspecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.mini)
                    Text(AppLocalized("Asking Hugging Face what this repository contains…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let e = model.inspectError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
            if let id = model.busyModel {
                VStack(alignment: .leading, spacing: 4) {
                    Text((model.progress == nil ? AppLocalized("Loading ") : AppLocalized("Downloading ")) + id)
                        .font(.caption)
                    if let p = model.progress { ProgressView(value: p) } else { ProgressView() }
                }
            }
            if let e = model.errorText {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text(AppLocalized("Add a model"))
        } footer: {
            Text(AppLocalized("An MLX-format model from Hugging Face. It is checked first, then downloaded once into the library and run offline."))
                .font(.caption)
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent(AppLocalized("Folder")) {
                Text(model.usingCustomFolder ? AppLocalized("chosen in Files") : AppLocalized("app folder"))
                    .foregroundStyle(.secondary)
            }
            Text(model.libraryPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Button {
                model.showingFolderPicker = true
            } label: {
                Label(AppLocalized("Choose Folder…"), systemImage: "folder")
            }
            if model.usingCustomFolder {
                Button(role: .destructive) { model.useAppFolder() } label: {
                    Label(AppLocalized("Use the app folder instead"), systemImage: "arrow.uturn.backward")
                }
            }
            LabeledContent(AppLocalized("Free space")) {
                Text(model.freeBytes > 0 ? model.format(model.freeBytes) : "—")
                    .font(.callout.monospaced())
            }
        } header: {
            Text(AppLocalized("Storage"))
        } footer: {
            Text(AppLocalized("Models can live anywhere the Files app can reach. Nothing here is uploaded to iCloud — model files are excluded from backup."))
                .font(.caption)
        }
    }

    private var enginesSection: some View {
        Section(AppLocalized("Engines")) {
            LabeledContent(AppLocalized("On-device (MLX)")) {
                if let r = model.residentModel {
                    Text(AppLocalized("running ") + String(r.split(separator: "/").last ?? ""))
                        .foregroundStyle(Color.green)
                } else {
                    Text(model.models.isEmpty ? AppLocalized("no models") : AppLocalized("ready"))
                        .foregroundStyle(model.models.isEmpty ? Color.secondary : Color.green)
                }
            }
            LabeledContent(AppLocalized("Apple Intelligence")) {
                Text(model.appleIntelligenceStatus)
                    .foregroundStyle(model.appleIntelligenceStatus == "available" ? Color.green : Color.secondary)
            }
        }
    }

    private var hardwareSection: some View {
        Section(AppLocalized("Hardware")) {
            LabeledContent(AppLocalized("Memory available")) {
                Text(model.format(Int64(model.availableMemoryBytes))).font(.callout.monospaced())
            }
            LabeledContent(AppLocalized("Increased memory limit")) {
                Text(model.memoryEntitlementGranted
                     ? AppLocalized("granted")
                     : AppLocalized("not granted — expect ~3.3 GB"))
                    .foregroundStyle(model.memoryEntitlementGranted ? Color.green : Color.orange)
            }
            LabeledContent(AppLocalized("GPU")) {
                Text(model.gpuName).font(.callout)
            }
            LabeledContent(AppLocalized("GPU working set")) {
                Text(model.format(Int64(clamping: model.gpuWorkingSetBytes))).font(.callout.monospaced())
            }
            LabeledContent(AppLocalized("Thermal state")) {
                Text(model.thermalState)
                    .foregroundStyle(model.thermalState == "nominal" ? Color.green : Color.orange)
            }
        }
    }

    private var footnoteSection: some View {
        Section {
            Text(AppLocalized("On-device models run entirely on this device. They use the GPU, count against the memory shown above, and slow down when the phone is warm — expect roughly 20% less throughput on a long run."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func modelRow(_ record: LocalModelInfo) -> some View {
        let isResident = model.residentModel == record.id
        let isBusy = model.busyModel == record.id
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(record.name).font(.subheadline).fontWeight(.medium)
                if isResident { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(Color.green) }
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

/// Confirmation before a multi-gigabyte download.
///
/// The point is that the user gets to see what they are about to spend: the real size on disk, how much
/// of it is weights, whether the repository is even the right format, and whether it will fit beside
/// whatever is already installed.
struct LocalModelConfirmView: View {
    let inspection: LocalModelInspection
    let freeBytes: Int64
    let format: (Int64) -> String
    let completion: (Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(inspection.name)
                        .font(.headline)
                    Text(inspection.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    if let rev = inspection.revision {
                        LabeledContent(AppLocalized("Revision")) {
                            Text(rev).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }

                Section(AppLocalized("Download")) {
                    LabeledContent(AppLocalized("Total size")) {
                        Text(format(inspection.totalBytes)).font(.callout.monospaced()).fontWeight(.medium)
                    }
                    LabeledContent(AppLocalized("Weights")) {
                        Text(format(inspection.weightBytes)).font(.callout.monospaced())
                    }
                    LabeledContent(AppLocalized("Files")) {
                        Text("\(inspection.files.count)").font(.callout.monospaced())
                    }
                    if freeBytes > 0 {
                        LabeledContent(AppLocalized("Free space")) {
                            Text(format(freeBytes)).font(.callout.monospaced())
                        }
                    }
                }

                if let warning = inspection.warning {
                    Section {
                        Label {
                            Text(warning).font(.caption)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                        }
                    }
                }

                Section(AppLocalized("Largest files")) {
                    ForEach(inspection.files.prefix(6), id: \.name) { f in
                        LabeledContent {
                            Text(format(f.size)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        } label: {
                            Text(f.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
            }
            .navigationTitle(AppLocalized("Download this model?"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { completion(false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("Download")) { completion(true) }
                        .disabled(!inspection.isLoadable)
                }
            }
        }
    }
}
