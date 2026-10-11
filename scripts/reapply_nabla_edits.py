#!/usr/bin/env python3
"""Re-apply this round's non-rebrand edits after reverting an unsafe blanket string pass.

The revert threw away BOTH the bad rebrand and the good provider wiring, because the working tree had
them blended. This restores the good part deterministically; the rebrand is then applied curated (see
reband_display_strings.py) rather than by a blanket literal substitution.
"""
from pathlib import Path

def patch(path, pairs):
    p = Path(path); t = p.read_text(); n = 0
    for old, new in pairs:
        c = t.count(old)
        if c != 1:
            raise SystemExit(f"!! {path}: expected 1 match, found {c} for {old[:70]!r}")
        t = t.replace(old, new); n += 1
    p.write_text(t); print(f"  {path}: {n}")

# a. cheap cached "is anything installed"
patch('Providers/LocalMLX/LocalModelHost.swift', [(
"""    static func installed() -> [LocalModelInfo] {""",
"""    /// Whether the library holds anything, cheaply.
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

    static func installed() -> [LocalModelInfo] {""")])

# b. the single "can anything serve a request?" predicate
patch('Providers/ProviderConfigStore.swift', [(
"""    static func builtInModels(for instance: ProviderInstance) -> [LLMModel] {""",
"""    /// Whether any provider can actually serve a request right now.
    ///
    /// [T-nabla-local-mlx-sentinel] The built-in on-device engine has no row in `config.instances` by
    /// design — synthetic, never persisted, never synced — so every "is there a provider?" check that
    /// reads `instances` alone answers "no" to a user who has a model installed and selected. That is not
    /// cosmetic: `AIChatViewModel.isReady` asks the same question, so the send button stayed disabled
    /// with a working engine right there. One predicate, here, instead of `!instances.isEmpty` copied
    /// into every call site.
    var hasUsableProvider: Bool {
        if config.instances.contains(where: { $0.isEnabled }) { return true }
        return LocalModelStore.hasInstalledModels
    }

    static func builtInModels(for instance: ProviderInstance) -> [LLMModel] {""")])

# c. the send-button gate
patch('Agent/Chat/AIChatViewModel.swift', [(
"""    var isReady: Bool {
        ProviderConfigStore.shared.instances.contains { $0.isEnabled }
    }""",
"""    var isReady: Bool {
        // [T-nabla-local-mlx-sentinel] Not `instances.contains { $0.isEnabled }`: the built-in
        // on-device engine is never in `instances`, so that form disabled sending for anyone using only
        // on-device models. `hasUsableProvider` answers what this flag actually means.
        ProviderConfigStore.shared.hasUsableProvider
    }""")])

# d/e. header + home gates
patch('Views/Chat/AIChatView.swift', [(
"""            hasProviders: !configStore.instances.isEmpty,""",
"""            hasProviders: configStore.hasUsableProvider,"""), (
"""        let hasProviders = !configStore.instances.isEmpty

        let isAuthed = hasBinding || hasProviders""",
"""        let hasProviders = configStore.hasUsableProvider

        let isAuthed = hasBinding || hasProviders""")])

patch('Views/ContentView.swift', [(
"""        let hasProviders = !providerStore.instances.isEmpty
        let hasGroups = !providerStore.modelGroups.isEmpty""",
"""        let hasProviders = providerStore.hasUsableProvider
        let hasGroups = !providerStore.modelGroups.isEmpty""")])

# f. Manage Providers row
patch('Views/Providers/ProviderInstancesView.swift', [(
"""            if store.instances.isEmpty {
                Section {""",
"""            // [T-nabla-local-mlx-sentinel] The built-in on-device engine is not in `store.instances`
            // (synthetic, never persisted), so the loop above cannot produce it — the picker's trick of
            // appending the section explicitly is repeated here, so the engine is discoverable wherever
            // providers are listed.
            Section {
                NavigationLink {
                    LocalInferenceSettingsView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AppLocalized("On this device"))
                            Text(LocalModelStore.hasInstalledModels
                                 ? AppLocalized("\\(LocalModelStore.installed().count) model(s) installed")
                                 : AppLocalized("No models installed yet"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(AppLocalized("Built-in"))
            } footer: {
                Text(AppLocalized("Runs models on this iPhone's GPU. No account, no API key — nothing leaves the device."))
            }

            if store.instances.isEmpty && !LocalModelStore.hasInstalledModels {
                Section {""")])

# g. Add Provider row
patch('Views/Providers/AddProviderView.swift', [(
"""        voiceProviderSection""",
"""        // [T-nabla-local-mlx-sentinel] A built-in engine rather than an account to add: the row leads to
        // the on-device model library (download, folder, storage) instead of a credential form.
        Section {
            NavigationLink {
                LocalInferenceSettingsView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "cpu.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AppLocalized("On this device"))
                        Text(LocalModelStore.hasInstalledModels
                             ? AppLocalized("\\(LocalModelStore.installed().count) model(s) installed")
                             : AppLocalized("Run MLX models on this iPhone's GPU"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(AppLocalized("Built-in"))
        } footer: {
            Text(AppLocalized("No account and no API key. Models are downloaded once and run offline on the GPU."))
        }

        voiceProviderSection""")])

# h. keep the cached library flag honest
patch('Views/Settings/LocalInferenceSettingsView.swift', [(
"""    func refresh() {
        models = LocalModelStore.installed()""",
"""    func refresh() {
        // The rest of the app gates on "is anything installed" through a short-lived cache, so a change
        // here must invalidate it — otherwise the provider screens keep showing the previous answer.
        LocalModelStore.invalidateInstalledCache()
        models = LocalModelStore.installed()""")])

print("non-rebrand edits restored")
