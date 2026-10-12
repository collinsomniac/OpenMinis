import SwiftUI
import Metal
import UniformTypeIdentifiers

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Local Inference settings
//
// [T-nabla-local-inference] The app's settings area for models that are *not* behind a network provider.
// On-device models are artefacts on disk with sizes, load costs and a fixed memory budget — a credential
// form cannot express "5.16 GB, resident, 11 tok/s, and it will not fit beside anything else". So this
// page manages the library, the folder it lives in, the memory question, and the measurements that
// answer "why is it slow?".

struct LocalAttempt: Sendable { var id: String; var outcome: String }

@MainActor
final class LocalInferenceModel: ObservableObject {
    @Published var models: [LocalModelInfo] = []
    /// Library folders that are not loadable models — a download that did not finish, or a folder that
    /// lost its weights. Listed so they can be seen and deleted; `installed()` deliberately hides them.
    @Published var incomplete: [(id: String, bytes: Int64)] = []
    @Published var libraryPath: String = ""
    @Published var usingCustomFolder = false
    @Published var availableMemoryBytes: Int = 0
    @Published var memoryEntitlementGranted = false
    @Published var thermalState: String = "?"
    @Published var gpuName: String = "?"
    @Published var gpuWorkingSetBytes: UInt64 = 0
    @Published var appleIntelligenceStatus: String = "unknown"
    @Published var errorText: String?
    @Published var downloadField: String = ""
    @Published var freeBytes: Int64 = 0
    @Published var lowPowerMode = false
    @Published var batteryLevel: Int = -1
    @Published var batteryState: String = "?"
    @Published var kvPrecision: LocalKVCachePreference = .eightBit(from: 2048)
    // add-model flow
    @Published var inspecting = false
    @Published var inspection: LocalModelInspection?
    @Published var inspectError: String?
    // folder picker
    @Published var showingFolderPicker = false
    // engine + measurement
    @Published var resident: String?
    @Published var loading: String?
    @Published var stats: LocalGenStats?
    @Published var benching = false
    @Published var benchResult: LocalGenStats?
    /// The last load request and its outcome, verbatim. Turns "it just doesn't load" into a readable line.
    @Published var lastAttempt: LocalAttempt?

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    nonisolated func format(_ bytes: Int64) -> String { Self.byteFormatter.string(fromByteCount: bytes) }

    func refresh() {
        LocalModelStore.invalidateInstalledCache()
        models = LocalModelStore.installed()
        let fm = FileManager.default
        let root = LocalModelStore.root
        let good = Set(models.map { $0.dir.standardizedFileURL.path })
        incomplete = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !good.contains($0.standardizedFileURL.path) }
            .map { dir in
                let id = dir.lastPathComponent.replacingOccurrences(of: "__", with: "/")
                var total: Int64 = 0
                if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let u as URL in e {
                        total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }
                return (id: id, bytes: total)
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
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        batteryLevel = level < 0 ? -1 : Int(level * 100)
        switch UIDevice.current.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "on battery"
        default: batteryState = "unknown"
        }
        kvPrecision = LocalKVCachePreference.current

        Task {
            let s = await LocalModelHost.shared.status()
            resident = s.resident ? s.modelId : nil
            let st = await MainActor.run { LocalEngineState.shared }
            if st.lastStats != nil { stats = st.lastStats }
            // The provider's model list follows the folder, so a change here must reach it.
            let store = ProviderConfigStore.shared
            for instance in store.instances where instance.providerType == .localMLX {
                await store.refreshModels(for: instance)
            }
        }
    }

    // MARK: - Library actions

    /// Will this model fit? Mirrors the engine's admission rule — weights **plus the KV cache the
    /// conversation will need** — so the warning is actionable rather than alarming. (A weight-only
    /// multiplier previously claimed a 5.14 GB model "needs 6.93 GB"; its real cost is ~5.7 GB.)
    nonisolated static func fit(_ info: LocalModelInfo, available: Int) -> (fits: Bool, note: String) {
        let kv = LocalKVCachePreference.current
        let ctx = min(info.contextLength ?? 8192, LocalKVCachePreference.assumedContextTokens)
        let need = LocalModelStore.runCost(for: info, contextTokens: ctx, kvBits: kv.bits)
        let have = Int64(available)
        let f = ByteCountFormatter()
        let kvPerToken = Double(info.kvBytesPerToken) * Double(kv.bits) / 16.0
        let kvString = ByteCountFormatter.string(fromByteCount: Int64(kvPerToken), countStyle: .memory)
        if need <= have {
            return (true, "weights \(f.string(fromByteCount: info.bytes)), K/V \(kvString)/token")
        }
        return (false, "needs ~\(f.string(fromByteCount: need)) at \(ctx) tokens of context — more than the \(f.string(fromByteCount: have)) free. Lower KV precision, or use a smaller quantisation.")
    }

    /// [T-nabla-local-mlx-load-not-wedging] `guard loading == nil else { return }` made one stuck in-flight
    /// flag disable the button permanently — and because the engine's early return for an
    /// already-resident model published nothing, the row could never become resident again. Now: only
    /// one load at a time, the flag is cleared on every exit path, and every outcome is recorded.
    func load(_ id: String) {
        guard loading == nil else { return }
        loading = id
        errorText = nil
        lastAttempt = LocalAttempt(id: id, outcome: "loading…")
        Task {
            defer { loading = nil }
            let started = Date()
            do {
                _ = try await LocalModelHost.shared.load(id)
                let secs = Date().timeIntervalSince(started)
                lastAttempt = LocalAttempt(id: id, outcome: String(format: "loaded in %.1f s", secs))
                errorText = nil
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                errorText = message
                lastAttempt = LocalAttempt(id: id, outcome: "refused: \(message)")
            }
            refresh()
        }
    }

    func unload() {
        Task {
            await LocalModelHost.shared.unload()
            stats = nil
            refresh()
        }
    }

    func delete(_ id: String) {
        Task {
            // Unload first and WAIT: deleting the files under a resident model would pull the weights out
            // from under the GPU mid-graph.
            if resident == id { await LocalModelHost.shared.unload() }
            try? LocalModelStore.remove(id)
            refresh()
        }
    }

    func measure(_ id: String) {
        guard !benching else { return }
        benching = true
        benchResult = nil
        Task {
            do {
                benchResult = try await LocalModelHost.shared.benchmark(id)
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            benching = false
            refresh()
        }
    }

    // MARK: - Add a model (check, then confirm, then download in the background)

    func beginAdd(_ raw: String) {
        let repo = LocalModelCatalog.normalize(raw)
        guard !repo.isEmpty, !inspecting else { return }
        inspecting = true
        inspectError = nil
        downloadField = ""
        Task {
            do { inspection = try await LocalModelCatalog.inspect(repo) }
            catch { inspectError = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
            inspecting = false
        }
    }

    /// Start the background download. Nothing is loaded — load is a separate, explicit step, because a
    /// download that also tries to run the model is how a 5 GB file becomes a jetsam kill.
    func confirmDownload(_ inspection: LocalModelInspection) {
        self.inspection = nil
        guard let rev = inspection.revision else {
            inspectError = "Hugging Face did not report a revision, so the download would not be pinned to a fixed snapshot."
            return
        }
        LocalModelDownloader.shared.start(repo: inspection.id, revision: rev, files: inspection.files)
    }

    // MARK: - Folder

    func chooseFolder(_ url: URL) {
        do { try LocalModelStore.setRoot(url) }
        catch { errorText = "Could not use that folder: \(error.localizedDescription)" }
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
    @ObservedObject private var downloads = LocalModelDownloader.shared
    @ObservedObject private var engine = LocalEngineState.shared

    var body: some View {
        List {
            modelsSection
            incompleteSection
            downloadsSection
            addSection
            performanceSection
            kvSection
            storageSection
            enginesSection
            diagnosticsSection
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
            if case .success(let urls) = result, let url = urls.first { model.chooseFolder(url) }
        }
        .sheet(item: $model.inspection) { inspection in
            LocalModelConfirmView(inspection: inspection,
                                  availableMemory: model.availableMemoryBytes,
                                  freeBytes: model.freeBytes,
                                  format: model.format) { confirmed in
                if confirmed { model.confirmDownload(inspection) } else { model.inspection = nil }
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
        } footer: {
            if let e = model.errorText {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ record: LocalModelInfo) -> some View {
        let isResident = engine.residentModelId == record.id
        let isLoading = model.loading == record.id
        let fit = LocalInferenceModel.fit(record, available: model.availableMemoryBytes)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(record.name).font(.subheadline).fontWeight(.medium)
                if isResident { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(Color.green) }
                Spacer()
                Text(model.format(record.bytes))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                tag(record.modelType)
                // Capabilities, read from the checkpoint. "can see images" is load-bearing: it is what
                // makes the app hand a photo to the model instead of a screenshot tool.
                if record.kind == .vision { tag(AppLocalized("images")) }
                if record.thinkingCapable { tag(AppLocalized("can think")) }
                if let ctx = record.contextLength { tag("\(ctx / 1024)k ctx") }
                if record.kind == .unsupported { tag(AppLocalized("not a chat model")) }
            }
            if !fit.fits {
                Label(fit.note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(Color.orange)
            } else {
                Text(fit.note).font(.caption2).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.mini)
                } else if isResident {
                    Button(AppLocalized("Measure")) { model.measure(record.id) }
                        .font(.caption).buttonStyle(.bordered)
                    Button(AppLocalized("Unload")) { model.unload() }
                        .font(.caption).buttonStyle(.bordered)
                } else {
                    Button(AppLocalized("Load")) { model.load(record.id) }
                        .font(.caption).buttonStyle(.borderedProminent)
                        .disabled(engine.loadingModelId != nil || record.kind == .unsupported)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var incompleteSection: some View {
        Group {
            if !model.incomplete.isEmpty {
                Section {
                    ForEach(model.incomplete, id: \.id) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.id.split(separator: "/").last.map(String.init) ?? item.id)
                                    .font(.subheadline)
                                Text(item.bytes > 0
                                     ? "\(model.format(item.bytes)) — not a loadable model"
                                     : AppLocalized("empty folder — a download that did not finish"))
                                    .font(.caption2).foregroundStyle(Color.orange)
                            }
                            Spacer()
                            Button(role: .destructive) { model.delete(item.id) } label: {
                                Text(AppLocalized("Delete"))
                            }
                            .font(.caption)
                        }
                    }
                } header: {
                    Text(AppLocalized("Incomplete"))
                } footer: {
                    Text(AppLocalized("These folders are not runnable models, so they never appear in the model list or the picker. Delete one and download again."))
                        .font(.caption)
                }
            }
        }
    }

    private var downloadsSection: some View {
        Group {
            if !downloads.jobs.isEmpty {
                Section {
                    ForEach(downloads.jobs) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(job.id.split(separator: "/").last.map(String.init) ?? job.id)
                                    .font(.subheadline).fontWeight(.medium)
                                Spacer()
                                Text("\(Int(job.fraction * 100))%")
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            ProgressView(value: job.fraction)
                            HStack {
                                Text("\(model.format(job.doneBytes)) of \(model.format(job.totalBytes))")
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                Button(AppLocalized("Cancel"), role: .destructive) {
                                    LocalModelDownloader.shared.cancel(repo: job.id)
                                }
                                .font(.caption2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text(AppLocalized("Downloading"))
                } header: {
                    Text(AppLocalized("Downloading"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppLocalized("Downloads continue while the app is in the background."))
                        if let e = downloads.lastError {
                            Text(e).foregroundStyle(Color.orange)
                        }
                    }
                    .font(.caption)
                }
            }
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
        } header: {
            Text(AppLocalized("Add a model"))
        } footer: {
            Text(AppLocalized("An MLX-format model from Hugging Face. It is checked first, then downloaded into the library and run offline."))
                .font(.caption)
        }
    }

    private var performanceSection: some View {
        Section {
            if let b = model.benchResult {
                statRow(AppLocalized("Benchmark"), value: speed(b.decodeTokensPerSecond),
                        detail: AppLocalized("short prompt, no history"))
            }
            if let s = model.stats {
                statRow(AppLocalized("Last turn"), value: speed(s.decodeTokensPerSecond),
                        detail: "\(s.generatedTokens) tok · TTFT \(Int(s.timeToFirstToken * 1000)) ms")
                LabeledContent(AppLocalized("Prompt")) {
                    Text("\(s.promptTokens) tok · \(s.reusedTokens) reused · \(Int(s.prefillSeconds * 1000)) ms prefill")
                        .font(.caption.monospaced())
                }
            } else if model.benchResult == nil {
                Text(AppLocalized("Load a model and Measure it, or send a message, to see real speeds here."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.benching {
                HStack(spacing: 8) { ProgressView().controlSize(.mini); Text(AppLocalized("Measuring…")).font(.caption) }
            }
            LabeledContent(AppLocalized("Thermal state")) {
                Text(model.thermalState)
                    .foregroundStyle(model.thermalState == "nominal" ? Color.green : Color.orange)
            }
        } header: {
            Text(AppLocalized("Performance"))
        } footer: {
            Text(AppLocalized("On-device speed is decided by memory bandwidth, so it falls as context grows and when the phone is warm. A short-prompt benchmark is the engine's ceiling; the per-turn line is what you actually get."))
                .font(.caption)
        }
    }

    private func speed(_ tps: Double) -> String {
        tps > 0 ? String(format: "%.1f tok/s", tps) : "—"
    }

    private func statRow(_ title: String, value: String, detail: String) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.callout.monospaced()).fontWeight(.medium)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent(AppLocalized("Folder")) {
                Text(model.usingCustomFolder ? AppLocalized("chosen in Files") : AppLocalized("app folder"))
                    .foregroundStyle(.secondary)
            }
            Text(model.libraryPath).font(.caption2.monospaced()).foregroundStyle(.secondary)
            Button { model.showingFolderPicker = true } label: {
                Label(AppLocalized("Choose Folder…"), systemImage: "folder")
            }
            if model.usingCustomFolder {
                Button(role: .destructive) { model.useAppFolder() } label: {
                    Label(AppLocalized("Use the app folder instead"), systemImage: "arrow.uturn.backward")
                }
            }
            LabeledContent(AppLocalized("Free space")) {
                Text(model.freeBytes > 0 ? model.format(model.freeBytes) : "—").font(.callout.monospaced())
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
                if let r = engine.residentModelId {
                    Text(AppLocalized("running ") + String(r.split(separator: "/").last ?? ""))
                        .foregroundStyle(Color.green)
                } else if let l = engine.loadingModelId {
                    Text(AppLocalized("loading ") + String(l.split(separator: "/").last ?? ""))
                        .foregroundStyle(Color.secondary)
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

    private var kvSection: some View {
        Section {
            Picker(AppLocalized("KV cache precision"), selection: Binding(
                get: { model.kvPrecision },
                set: { newValue in
                    model.kvPrecision = newValue
                    UserDefaults.standard.set(
                        { switch newValue { case .full: return "full"; case .fourBit: return "4"; case .eightBit: return "8" } }(),
                        forKey: LocalKVCachePreference.key)
                    UserDefaults.standard.set(Double(newValue.startTokens), forKey: LocalKVCachePreference.startKey)
                    // The cache plan changes, so the next turn rebuilds it (the library compares plans).
                })) {
                Text("Full precision").tag(LocalKVCachePreference.full)
                Text("8-bit").tag(LocalKVCachePreference.eightBit(from: 0))
                Text("8-bit after 2k").tag(LocalKVCachePreference.eightBit(from: 2048))
                Text("4-bit after 2k").tag(LocalKVCachePreference.fourBit(from: 2048))
            }
            if let s = model.stats, s.kvBytesPerToken > 0 {
                LabeledContent(AppLocalized("K/V per context token")) {
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(Double(s.kvBytesPerToken) * Double(s.kvBits) / 16.0),
                        countStyle: .memory))
                        .font(.callout.monospaced())
                }
            }
        } header: {
            Text(AppLocalized("KV cache"))
        } footer: {
            Text(AppLocalized("K/V is re-read for every generated token, so at long context its size sets the decode rate — often costing more than the weights. Quantising it is where on-device speed comes from; keeping the first 2k tokens in full precision leaves short chats untouched. Changing this rebuilds the cache on the next turn."))
                .font(.caption)
        }
    }

    private var diagnosticsSection: some View {
        Group {
            if model.lastAttempt != nil || engine.lastRefusal != nil {
                Section(AppLocalized("Diagnostics")) {
                    if let a = model.lastAttempt {
                        LabeledContent(AppLocalized("Last load")) {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(a.id.split(separator: "/").last.map(String.init) ?? a.id)
                                    .font(.caption.monospaced())
                                Text(a.outcome).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let r = engine.lastRefusal {
                        Text(r).font(.caption).foregroundStyle(Color.orange)
                    }
                }
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
            LabeledContent(AppLocalized("GPU")) { Text(model.gpuName).font(.callout) }
            LabeledContent(AppLocalized("GPU working set")) {
                Text(model.format(Int64(clamping: model.gpuWorkingSetBytes))).font(.callout.monospaced())
            }
            LabeledContent(AppLocalized("Low Power Mode")) {
                Text(model.lowPowerMode ? AppLocalized("on — expect roughly half speed") : AppLocalized("off"))
                    .foregroundStyle(model.lowPowerMode ? Color.orange : Color.secondary)
            }
            LabeledContent(AppLocalized("Battery")) {
                Text(model.batteryLevel >= 0 ? "\(model.batteryLevel)% · \(model.batteryState)" : model.batteryState)
                    .foregroundStyle(model.batteryLevel >= 0 && model.batteryLevel < 25 ? Color.orange : Color.secondary)
            }
        }
    }

    private var footnoteSection: some View {
        Section {
            Text(AppLocalized("One on-device model is resident at a time: they are large enough that two cannot share the memory budget. Loading a different model unloads the current one first."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
/// of it is weights, whether the repository is even the right format — and whether it will fit, which is
/// the difference between a model that runs and a process that gets killed.
struct LocalModelConfirmView: View {
    let inspection: LocalModelInspection
    let availableMemory: Int
    let freeBytes: Int64
    let format: (Int64) -> String
    let completion: (Bool) -> Void

    private var memoryNote: (ok: Bool, text: String) {
        let need = Int64(Double(inspection.weightBytes) * 1.35)
        let f = ByteCountFormatter()
        if need <= Int64(availableMemory) {
            return (true, "Weights are \(f.string(fromByteCount: inspection.weightBytes)); it fits in the \(f.string(fromByteCount: Int64(availableMemory))) available.")
        }
        return (false, "Weights are \(f.string(fromByteCount: inspection.weightBytes)) and this model needs about \(f.string(fromByteCount: need)) with working room — more than the \(f.string(fromByteCount: Int64(availableMemory))) free. It will download, but loading it will be refused. A 4-bit build of the same model is usually about half the size.")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(inspection.name).font(.headline)
                    Text(inspection.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let rev = inspection.shortRevision {
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

                Section(AppLocalized("Will it run?")) {
                    Label {
                        Text(memoryNote.text).font(.caption)
                    } icon: {
                        Image(systemName: memoryNote.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(memoryNote.ok ? Color.green : Color.orange)
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
