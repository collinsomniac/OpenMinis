#!/usr/bin/env python3
"""Make on-device inference a real ProviderType (`.localMLX`) and remove the sentinel workaround.

Why: the sentinel provider (synthetic instance, never persisted) could be listed and picked, but a
session stores its choice as a *model entry* id and `ProviderConfigStore.entry(for:)` resolves only
persisted `config.modelEntries` (with a special case for the System voice engine alone). So the pick
never resolved: the chat header showed the raw `__builtin_local_mlx__/…` id and sending could not
proceed. Every surface patched one at a time is the wrong shape; the provider must be a real instance
with real entries, exactly like the vendor providers.

Forward compatibility is already designed in: an unknown provider-type string decodes to
`.unsupported` (and keeps the raw string), so a peer on an older build degrades rather than failing.

Run from src/ios. Every edit asserts its match count so a drifted file fails loudly.
"""
import re
from pathlib import Path

def edit(path, pairs):
    p = Path(path); t = p.read_text(); n = 0
    for old, new, *cnt in pairs:
        want = cnt[0] if cnt else 1
        c = t.count(old)
        if c != want:
            raise SystemExit(f"!! {path}: expected {want} of {old[:80]!r}, found {c}")
        t = t.replace(old, new); n += 1
    p.write_text(t); print(f"  {path}: {n}")

# ───────────────────────── 1. the type itself ─────────────────────────
edit('Providers/ProviderTypes.swift', [
 ("""    case githubCopilot
""", """    case githubCopilot
    /// [T-nabla-local-mlx-provider] On-device inference: MLX models from the library folder
    /// (Settings → Local Inference). No account, no key, no network. Its model list is read from disk
    /// rather than fetched, but otherwise it is an ordinary instance with ordinary entries, so every
    /// path that resolves a selected model — sessions, groups, the picker, fallback — works unchanged.
    /// An older build decodes this raw value to `.unsupported`, which is the designed degradation.
    case localMLX
"""),
 ("""        case .githubCopilot: return "GitHub Copilot"
        case .unsupported: return "Unsupported\"""",
  """        case .githubCopilot: return "GitHub Copilot"
        case .localMLX: return "On-Device (MLX)"
        case .unsupported: return "Unsupported\""""),
 ("""        case .unsupported:
            // Synced from a newer build — nothing to fetch with.
            return false""",
  """        case .localMLX:
            // No OAuth, and nothing to discover over a network: the library folder is the catalog.
            return false
        case .unsupported:
            // Synced from a newer build — nothing to fetch with.
            return false"""),
 ("""        case .githubCopilot: return []
        case .unsupported: return []""",
  """        case .githubCopilot: return []
        case .localMLX: return LLMModel.allLocalMLX
        case .unsupported: return []"""),
 ("""        case .antigravity:
            return AppLocalized("\\(builtInModels.count) built-in models")""",
  """        case .localMLX:
            return AppLocalized("Runs MLX models from this iPhone's library — no account, no API key")
        case .antigravity:
            return AppLocalized("\\(builtInModels.count) built-in models")"""),
 ("""        case .githubCopilot: return .vision
        case .unsupported: return .vision""",
  """        case .githubCopilot: return .vision
        case .localMLX: return .textOnly
        case .unsupported: return .vision"""),
])

# ───────────────────────── 2. instance capabilities ─────────────────────────
edit('Providers/ProviderInstance.swift', [
 ("""        case .gemini, .antigravity, .githubCopilot, .unsupported:
            return false
        }
    }""",
  """        case .gemini, .antigravity, .githubCopilot, .localMLX, .unsupported:
            return false
        }
    }"""),
 ("""        case .anthropic, .gemini, .antigravity, .unsupported:
            return false
        }""",
  """        case .anthropic, .gemini, .antigravity, .localMLX, .unsupported:
            return false
        }"""),
 ("""    var allowsEmptyAPIKey: Bool {
        guard credentialType == .apiKey,""",
  """    var allowsEmptyAPIKey: Bool {
        // [T-nabla-local-mlx-provider] Keyless by nature — configured-by-definition, so routing
        // (`hasAnyCredential`) and the provider row treat it as ready without a Keychain probe.
        if providerType == .localMLX { return true }
        guard credentialType == .apiKey,"""),
 ("""        case .antigravity, .openRouter, .unsupported:
            // unsupported = synced from a newer build; no usable credential here.""",
  """        case .localMLX:
            return true   // unreachable in practice: allowsEmptyAPIKey answers first
        case .antigravity, .openRouter, .unsupported:
            // unsupported = synced from a newer build; no usable credential here."""),
])

edit('Providers/ProviderMigration.swift', [
 ("""            case .unsupported:
                break""",
  """            case .localMLX:
                // [T-nabla-local-mlx-provider] New, keyless — nothing to migrate.
                break
            case .unsupported:
                break"""),
])

# ───────────────────────── 3. model list + base URL ─────────────────────────
edit('Providers/ProviderConfigStore.swift', [
 ("""        case (.unsupported, _):
            // Synced from a newer build — can't fetch; keep whatever's stored.
            return []""",
  """        case (.localMLX, _):
            // [T-nabla-local-mlx-provider] The catalog is the library folder: whatever is installed
            // is exactly what can run. Same refresh → replaceEntries path as every vendor, so the
            // provider's model list (and the user's show/hide choices on it) behave the same way.
            return LLMModel.allLocalMLX
        case (.unsupported, _):
            // Synced from a newer build — can't fetch; keep whatever's stored.
            return []"""),
 ("""        case .antigravity: return nil // No public base URL
        case .unsupported: return nil // synced from newer build""",
  """        case .antigravity: return nil // No public base URL
        case .localMLX: return nil // on-device; no endpoint
        case .unsupported: return nil // synced from newer build"""),
])

# ───────────────────────── 4. factories ─────────────────────────
edit('Providers/LLMProviderFactory.swift', [
 ("""        case .unsupported:
            throw FactoryError.voiceOnlyProvider
        }""",
  """        case .localMLX:
            return LocalMLXProvider(model: entry.model)
        case .unsupported:
            throw FactoryError.voiceOnlyProvider
        }"""),
])
edit('Agent/Chat/AIChatViewModel+ProviderFactory.swift', [
 ("""        case .unsupported:
            logger.error("\\(instance.providerType) has no agent provider; returning placeholder")""",
  """        case .localMLX:
            return LocalMLXAgentProvider(model: entry.model)
        case .unsupported:
            logger.error("\\(instance.providerType) has no agent provider; returning placeholder")"""),
 ("""        case .unsupported:
            throw LLMProviderError.noCredentials
        }
    }""",
  """        case .localMLX:
            return LocalMLXProvider(model: entry.model)
        case .unsupported:
            throw LLMProviderError.noCredentials
        }
    }"""),
])

# ───────────────────────── 5. reasoning / thinking display ─────────────────────────
edit('Agent/Chat/AIChatViewModel.swift', [
 ("""        case .openRouter, .xAI, .kimiCode:
            return true""",
  """        case .openRouter, .xAI, .kimiCode, .localMLX:
            // localMLX: thinking is a chat-template switch (`enable_thinking`), so the toggle is
            // meaningful for any model whose template supports it.
            return true"""),
 ("""            case .unsupported:
                level = "—\"""",
  """            case .localMLX:
                level = thinkLvl.displayName
            case .unsupported:
                level = "—\""""),
])

# ───────────────────────── 6. backup / debug / offload / voice ─────────────────────────
edit('Agent/Backup/BackupSecrets.swift', [
 ("""        case .antigravity, .openAIResponses, .openRouter, .unsupported:
            return nil""",
  """        case .antigravity, .openAIResponses, .openRouter, .localMLX, .unsupported:
            return nil"""),
])
edit('Debug/DebugRPCProviderChat.swift', [
 ("""            case .unsupported: supportedCreds = []""",
  """            case .localMLX: supportedCreds = ["apiKey"]
            case .unsupported: supportedCreds = []"""),
 ("""            case .anthropic, .antigravity, .githubCopilot, .unsupported: customBaseSupported = false""",
  """            case .anthropic, .antigravity, .githubCopilot, .localMLX, .unsupported: customBaseSupported = false"""),
])
edit('NativeOffloads/ModelUseOffloadBridge.swift', [
 ("""        case .unsupported:
            return \"\"""", """        case .unsupported, .localMLX:
            return \"\""""),
])
edit('Providers/Voice/VoiceProviderFactory.swift', [
 ("""        case .antigravity, .kimiCode, .githubCopilot, .unsupported:""",
  """        case .antigravity, .kimiCode, .githubCopilot, .localMLX, .unsupported:""", 2),
])

# ───────────────────────── 7. provider list row ─────────────────────────
edit('Views/Providers/ProviderInstancesView.swift', [
 ("""        case .unsupported: return false // synced from newer build
        }
    }""",
  """        case .localMLX: return false // keyless; never OAuth
        case .unsupported: return false // synced from newer build
        }
    }"""),
])

# ───────────────────────── 8. instance detail view ─────────────────────────
edit('Views/Providers/ProviderInstanceDetailView.swift', [
 ("""        case .unsupported: return "—\"""", """        case .localMLX: return AppLocalized("On this device")
        case .unsupported: return "—\""""),
 ("""        case .unsupported: return false // synced from newer build""",
  """        case .localMLX: return false
        case .unsupported: return false // synced from newer build"""),
 ("""        case .unsupported:
            return AppLocalized("Unsupported in this app version")""",
  """        case .localMLX:
            return AppLocalized("No sign-in needed")
        case .unsupported:
            return AppLocalized("Unsupported in this app version")"""),
 ("""        case .unsupported: return AppLocalized("Sign In")
        }
    }

    private func oauthLogin""",
  """        case .localMLX: return AppLocalized("Sign In")
        case .unsupported: return AppLocalized("Sign In")
        }
    }

    private func oauthLogin"""),
 ("""            case .githubCopilot: break // device-code flow runs in CopilotDeviceLoginSheet
            case .unsupported: break""",
  """            case .githubCopilot: break // device-code flow runs in CopilotDeviceLoginSheet
            case .localMLX: break
            case .unsupported: break"""),
 ("""        case .githubCopilot: CopilotOAuthManager.shared.logout(instanceId: instance.id)
        case .unsupported: break""",
  """        case .githubCopilot: CopilotOAuthManager.shared.logout(instanceId: instance.id)
        case .localMLX: break
        case .unsupported: break"""),
 ("""        case .unsupported:
            token = nil
        }
        guard let token, !token.isEmpty else { return }""",
  """        case .localMLX, .unsupported:
            token = nil
        }
        guard let token, !token.isEmpty else { return }"""),
 ("""        case .openAIResponses: return "sk-..."
        case .unsupported: return ""
        }
    }""",
  """        case .openAIResponses: return "sk-..."
        case .localMLX: return ""
        case .unsupported: return ""
        }
    }"""),
 # replace credential + base URL sections with a library section for this type
 ("""            // MARK: Credential
            Section {
                credentialSection(instance)
            } header: {
                Text("Credential")
            } footer: {
                Text(instance.credentialType == .apiKey
                     ? "API key is stored securely in the iOS Keychain."
                     : "OAuth tokens are stored per-instance in the iOS Keychain.")
            }

            // MARK: Custom Base URL
            customBaseURLSection(instance)
""",
  """            if instance.providerType == .localMLX {
                // [T-nabla-local-mlx-provider] No credential and no endpoint. In their place: where
                // the models come from, and a one-tap re-read of the library. The model list below
                // is the same list every provider shows, with the same show/hide controls.
                Section {
                    NavigationLink {
                        LocalInferenceSettingsView()
                    } label: {
                        Label(AppLocalized("Model library"), systemImage: "cpu")
                    }
                    Button {
                        Task { await store.refreshModels(for: instance) }
                    } label: {
                        Label(AppLocalized("Reload models from library"), systemImage: "arrow.clockwise")
                    }
                } header: {
                    Text(AppLocalized("On this device"))
                } footer: {
                    Text(AppLocalized("Models are read from the library folder. Download, delete, or move the folder in Model library; the list below follows it."))
                }
            } else {
            // MARK: Credential
            Section {
                credentialSection(instance)
            } header: {
                Text("Credential")
            } footer: {
                Text(instance.credentialType == .apiKey
                     ? "API key is stored securely in the iOS Keychain."
                     : "OAuth tokens are stored per-instance in the iOS Keychain.")
            }

            // MARK: Custom Base URL
            customBaseURLSection(instance)
            }
"""),
])

# ───────────────────────── 9. Add Provider flow ─────────────────────────
edit('Views/Providers/AddProviderView.swift', [
 ("""            case .githubCopilot: break
            case .unsupported: break // free / unsupported — no OAuth""",
  """            case .githubCopilot: break
            case .localMLX: break // keyless
            case .unsupported: break // free / unsupported — no OAuth"""),
 ("""        case .unsupported:
            token = nil // free / unsupported — no token""",
  """        case .localMLX, .unsupported:
            token = nil // keyless / unsupported — no token"""),
 ("""        case .githubCopilot: return AppLocalized("Sign in with GitHub")
        case .unsupported: return AppLocalized("Sign In")
        }
    }""",
  """        case .githubCopilot: return AppLocalized("Sign in with GitHub")
        case .localMLX: return AppLocalized("Sign In")
        case .unsupported: return AppLocalized("Sign In")
        }
    }"""),
 ("""        case .githubCopilot: return "" // OAuth only
        case .unsupported: return ""
        }""",
  """        case .githubCopilot: return "" // OAuth only
        case .localMLX: return ""
        case .unsupported: return ""
        }"""),
 ("""        case .githubCopilot: return "GitHub Copilot"
        case .unsupported: return AppLocalized("Unsupported")""",
  """        case .githubCopilot: return "GitHub Copilot"
        case .localMLX: return AppLocalized("On-Device (MLX)")
        case .unsupported: return AppLocalized("Unsupported")"""),
 ("""        case (.unsupported, _):
            return AppLocalized("This provider isn't supported in this app version.")""",
  """        case (.localMLX, _):
            return AppLocalized("No key needed — models run on this iPhone.")
        case (.unsupported, _):
            return AppLocalized("This provider isn't supported in this app version.")"""),
 ("""        case .unsupported:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.gray)""",
  """        case .localMLX:
            Image(systemName: "cpu")
                .foregroundStyle(.blue)
        case .unsupported:
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.gray)"""),
 ("""        case .githubCopilot: return .primary
        case .unsupported: return .gray""",
  """        case .githubCopilot: return .primary
        case .localMLX: return .blue
        case .unsupported: return .gray"""),
 ("""        case .githubCopilot:
            return [.oauth]
        case .openAIResponses, .gemini:
            return [.apiKey]""",
  """        case .githubCopilot:
            return [.oauth]
        // [T-nabla-local-mlx-provider] Keyless. `.apiKey` with an empty key is the existing
        // "configured-by-definition" shape (see allowsEmptyAPIKey), so no new credential kind.
        case .openAIResponses, .gemini, .localMLX:
            return [.apiKey]"""),
 # empty key allowed for local, regardless of base URL
 ("""    private var emptyKeyAllowedForCurrentInput: Bool {
        guard selectedCredential == .apiKey,""",
  """    private var emptyKeyAllowedForCurrentInput: Bool {
        if selectedType == .localMLX, selectedCredential == .apiKey { return true }
        guard selectedCredential == .apiKey,"""),
 # choosing the type skips the credential step (there is no credential to choose)
 ("""                Button {
                    selectedType = type
                    // Only seed the label when the user hasn't typed""",
  """                Button {
                    selectedType = type
                    // [T-nabla-local-mlx-provider] Nothing to authenticate: go straight to configure.
                    if type == .localMLX { selectedCredential = .apiKey }
                    // Only seed the label when the user hasn't typed"""),
 # back from configure returns to the type list for local (no credential step to land on)
 ("""    private func goBack() {""",
  """    private func goBack() {
        if selectedType == .localMLX {
            selectedType = nil
            selectedCredential = nil
            errorMessage = nil
            return
        }"""),
 # configure step: library section instead of API key / OAuth
 ("""            if selectedCredential == .apiKey {
                apiKeySection
            } else {
                oauthSection
            }""",
  """            if selectedType == .localMLX {
                localMLXSection
            } else if selectedCredential == .apiKey {
                apiKeySection
            } else {
                oauthSection
            }"""),
 ("""    private var apiKeySection: some View {""",
  """    /// [T-nabla-local-mlx-provider] Configure step for the on-device provider: show what the library
    /// holds (these become the provider's models) and add it. Models are chosen afterwards in the
    /// provider's model list, exactly as for any other provider.
    private var localMLXSection: some View {
        let models = LocalModelStore.installed()
        return Group {
            Section {
                if models.isEmpty {
                    Text(AppLocalized("No models in the library yet. You can add the provider now and download models later from Settings → Local Inference."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(models, id: \\.id) { m in
                        LabeledContent {
                            Text(ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.name)
                                Text(m.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(AppLocalized("Models in your library"))
            } footer: {
                Text(AppLocalized("Read from the library folder. The provider's model list follows the folder as models are added or removed."))
            }

            Section {
                Button {
                    saveApiKeyInstance()
                } label: {
                    HStack {
                        Spacer()
                        if isSaving { ProgressView() } else {
                            Text(AppLocalized("Add Provider")).fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(isSaving)
            }
        }
    }

    private var apiKeySection: some View {"""),
])

# ───────────────────────── 10. remove the sentinel workaround ─────────────────────────
p = Path('Providers/LocalMLX/LocalMLXProvider.swift'); t = p.read_text()
s = t.index("extension LocalMLXProvider {")
e = t.index("/// Plain chat / completion provider")
t = t[:s] + t[e:]
s = t.index("extension ModelEntry {")
t = t[:s].rstrip() + "\n"
t = t.replace('provider: LocalMLXProvider.builtinProviderId)', 'provider: "localMLX")')
t = re.sub(r"// \[T-nabla-local-mlx-sentinel\].*?// Text only for now:", "// [T-nabla-local-mlx-provider] A real `ProviderType.localMLX`: instances are added through Add\n// Provider like any vendor, and the model list is the library folder (see fetchModelsForInstance).\n//\n// Text only for now:", t, flags=re.S)
p.write_text(t); print("  LocalMLXProvider.swift: sentinel extension + localMLXEntries removed")

edit('Providers/ProviderConfigStore.swift', [
 ("""        // [T-nabla-local-mlx-sentinel] The built-in on-device engine is the same shape of synthetic,
        // local-only instance: never in config.instances, so never in the DB and never synced.
        if LocalMLXProvider.ownsProviderId(id) {
            return LocalMLXProvider.providerInstance
        }
""", ""),
 ("""        if LocalMLXProvider.ownsProviderId(instance.id) { return LLMModel.allLocalMLX }
""", ""),
])
t = Path('Providers/ProviderConfigStore.swift').read_text()
t = re.sub(r"    /// Whether any provider can actually serve a request right now\..*?    var hasUsableProvider: Bool \{.*?\n    \}\n",
"""    /// Whether any provider can actually serve a request right now.
    ///
    /// The on-device engine is an ordinary instance now (`.localMLX`), so this is simply "any enabled
    /// instance" — kept as one named predicate so the call sites cannot drift apart again.
    var hasUsableProvider: Bool {
        config.instances.contains(where: { $0.isEnabled })
    }
""", t, count=1, flags=re.S)
Path('Providers/ProviderConfigStore.swift').write_text(t); print("  ProviderConfigStore: hasUsableProvider simplified")

t = Path('Providers/LLMProviderFactory.swift').read_text()
t2 = re.sub(r"        // \[T-nabla-local-mlx-sentinel\] Built-in on-device engine\..*?if LocalMLXProvider\.ownsProviderId\(instance\.id\) \{\n            return LocalMLXProvider\(model: entry\.model\)\n        \}\n", "", t, count=1, flags=re.S)
assert t2 != t; Path('Providers/LLMProviderFactory.swift').write_text(t2); print("  LLMProviderFactory: sentinel branch removed")

t = Path('Agent/Chat/AIChatViewModel+ProviderFactory.swift').read_text()
t2 = re.sub(r"        // \[T-nabla-local-mlx-sentinel\] Built-in on-device engine — see LLMProviderFactory\.\n        if LocalMLXProvider\.ownsProviderId\(instance\.id\) \{\n            return LocalMLXAgentProvider\(model: entry\.model\)\n        \}\n", "", t, count=1)
assert t2 != t; Path('Agent/Chat/AIChatViewModel+ProviderFactory.swift').write_text(t2); print("  makeAgentProvider: sentinel branch removed")

t = Path('Agent/Chat/AIChatViewModel.swift').read_text()
t = t.replace("""        // [T-nabla-local-mlx-sentinel] Not `instances.contains { $0.isEnabled }`: the built-in
        // on-device engine is never in `instances`, so that form disabled sending for anyone using only
        // on-device models. `hasUsableProvider` answers what this flag actually means.
""", "")
Path('Agent/Chat/AIChatViewModel.swift').write_text(t)

t = Path('Views/Providers/UnifiedModelPicker.swift').read_text()
t2 = re.sub(r"        // \[T-nabla-local-mlx-sentinel\] The built-in on-device engine's models come from.*?pool\.append\(contentsOf: ModelEntry\.localMLXEntries\(\)\)\n", "", t, count=1, flags=re.S)
t3 = re.sub(r"        // Same treatment for the built-in on-device engine:.*?\n        \}\n", "", t2, count=1, flags=re.S)
assert t2 != t and t3 != t2; Path('Views/Providers/UnifiedModelPicker.swift').write_text(t3); print("  UnifiedModelPicker: sentinel pool + section removed")

for path, marker_start, marker_end in [
    ('Views/Providers/ProviderInstancesView.swift',
     "            // [T-nabla-local-mlx-sentinel] The built-in on-device engine is not in `store.instances`",
     "            if store.instances.isEmpty && !LocalModelStore.hasInstalledModels {"),
    ('Views/Providers/AddProviderView.swift',
     "        // [T-nabla-local-mlx-sentinel] A built-in engine rather than an account to add",
     "        voiceProviderSection"),
]:
    t = Path(path).read_text()
    s = t.index(marker_start); e = t.index(marker_end)
    t = t[:s] + t[e:]
    t = t.replace("            if store.instances.isEmpty && !LocalModelStore.hasInstalledModels {", "            if store.instances.isEmpty {")
    Path(path).write_text(t); print(f"  {path}: sentinel row removed")

# ───────────────────────── 11. keep the provider's list in step with the folder ─────────────────────────
edit('Views/Settings/LocalInferenceSettingsView.swift', [
 ("""        LocalModelStore.invalidateInstalledCache()
        models = LocalModelStore.installed()""",
  """        LocalModelStore.invalidateInstalledCache()
        models = LocalModelStore.installed()
        // [T-nabla-local-mlx-provider] The on-device provider's model list IS the folder. Re-read it
        // whenever the library may have changed (download, delete, folder move), through the same
        // refresh path a vendor's /models fetch uses, so the picker never offers a model that is gone.
        let store = ProviderConfigStore.shared
        for instance in store.instances where instance.providerType == .localMLX {
            Task { await store.refreshModels(for: instance) }
        }"""),
])
print("done")
