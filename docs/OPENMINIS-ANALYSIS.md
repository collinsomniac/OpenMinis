# OpenMinis codebase analysis — for the Nabla work (2026-10-10)

Read before changing anything. Compiled from a full pass over the fork at
`src/ios` (commit `7eb48a8` + rebrand). Numbers are measured, not estimated.

## 1. Scale

| | |
|---|---|
| Swift files | **623** |
| Swift lines | **298,710** |
| total files (incl. assets, ObjC, C) | 846 |
| largest file | `Views/Chat/SelectableMarkdownView.swift` — 9,681 lines |
| then | `Views/ContentView.swift` 8,799 · `Agent/Chat/ChatStore.swift` 8,611 · `AIChatViewModel.swift` 8,028 · `AIChatView.swift` 7,008 |

By area (Swift LOC): `Agent` 97k · `Views` 77k · tests 45k · `Providers` 37k · `Debug` 15k ·
`Shared` 10.5k · `NativeOffloads` 5.6k · `iSH` 4.2k · `Diagnostics` 2.2k.

**This is a mature application, not a scaffold.** Anything we change has to fit three
hundred thousand lines of existing convention.

## 2. Architecture, layer by layer

### Entry and shell
- `MinisApp.swift` — SwiftUI `App` + `@UIApplicationDelegateAdaptor`. Uses the **UIKit scene lifecycle**
  (`AppDelegate.configurationForConnecting` → `SceneDelegate`), which iOS 27 now requires.
- `Views/ContentView.swift` — the whole shell: session list, iPad split layout, and (from ~line 8,100)
  the **settings sheet**. 34 top-level modifiers on its body; we split it into three stages because
  Xcode 27.0's type checker timed out on it.

### Settings — where our section goes
`private enum SettingsDestination` + `private struct SettingsSheet` inside `ContentView.swift`:
`List { Section { NavigationLink("Manage Providers") / ("Model Groups") … } }` and a
`navigationDestination(for: SettingsDestination.self)` switch.

A new settings area is therefore: **one enum case, one `NavigationLink`, one switch arm**, and a new
view under `Views/Settings/`. There are already 30 views there (Backup, Cloud Sync, Memory, Soul,
Tools, Storage, Mounted Folders, Permissions, Environment Variables, Logs…), so the idiom is
well-established and a *Local Inference* page sits naturally beside *Manage Providers*.

### The agent loop
- `Agent/Chat/` — 29 files. `AIChatViewModel` is `@MainActor final class` (8k lines) split into ~20
  extensions by concern: `+SSEStream`, `+ToolDefinitions`, `+ToolPreflight`, `+Fallback`,
  `+Compaction`, `+Offloading`, `+Persistence`, `+RequestBudget`, `+TitleGeneration`,
  `+ProviderFactory`, `+MemoryTools`, `+FileTools`, `+ISHCommand`, `+ConcurrentTools`,
  `+MentionMenu`, `+BackgroundTask`, `+ProgrammaticPrompt`, `+SlashCommands`, `+Attachments`, `+Misc`.
- `ChatStore.swift` — the session/message store (**SQLite3** directly, not Core Data/GRDB).
- Tool surface seen in `+ToolDefinitions`: `shell_execute`, `file_read`, `file_write`, `read_image`,
  `browser_use`, `memory_get`, `memory_write`, `task` (sub agents), plus ISH/shell paths.
- Providers are invoked as
  `let stream = try await currentProvider.streamAgentMessage(messages:systemPrompt:tools:maxTokens:thinkingLevel:)`
  — from `+Fallback` (primary + fallback), `+TitleGeneration` (cheap auxiliary calls).

### Providers
- Two protocols (`LLMProvider`, `AgentProvider`), 9 families
  (openAI, anthropic, gemini, antigravity, openRouter, openAIResponses, xAI, kimiCode, githubCopilot),
  plus an explicit `.unsupported` case **that decodes unknown ids instead of throwing** — forward
  compatibility is deliberate, and our new type must respect it.
- Construction is centralised in exactly two switches: `LLMProviderFactory.makeProvider` and
  `AIChatViewModel.makeAgentProvider`. Each provider is built from a `ProviderInstance`.
- `ProviderInstance` = `{id, label, providerType, credentialType, isEnabled, createdAt, customBaseURL,
  appendV1Suffix, imageEndpointMode, customUserAgent, azureMode, unknownProviderTypeRaw}`.
  **`credentialType` and `customBaseURL` are the fields that don't fit a local engine** — ours needs
  neither, so it needs either a new credential kind or to ignore them.
- Model lists per type come from statics (`ProviderType.allModels` → e.g. `LLMModel.allAnthropic`).
  `LLMModel.allLocalMLX` (written) plugs in here.
- Routing: `ModelGroupRouter` (fallback / load-balance), `ModelGroup`, `ModelEntry`
  (`compositeKey = providerInstanceId/baseModel.id`), `ThinkingRuleResolver` (57k — per-model
  reasoning-effort rules), `VisionGroupResolver` (37k), voice stack (~250k of Providers/).

### Persistence — three mechanisms, deliberately
| mechanism | files | used for |
|---|---|---|
| **SQLite3** | 14 | sessions/messages (`ChatStore`), and a **mirror of provider config** (`ProviderConfigDB`: `provider_instances`, `provider_model_entries`, `provider_model_groups`, `provider_local_kv`, `provider_session_bindings`, `provider_session_inference_configs`, `provider_agent_loop_ids`, `provider_thinking_rules`) |
| **JSON files** | 56 | explicit/serialised state |
| **UserDefaults** | 82 | preferences, small flags |

`ProviderConfigStore` (3,701 lines) is the single source of truth: JSON + a v3 SQLite mirror,
tombstones for deletions, keychain-sync observers, and **guarded loading with a degraded-recovery
path**. Adding a provider type touches the enum, the factory switches, and this store's
migration paths.

### Native and extension layers
- `NativeOffloads/*.m` (5.6k) — 9 **Objective-C** bridges (Alarm, BrowserUse, Config, Debug,
  ModelUse, Player, Scheduled, Sessions, Weather) importing the generated `Nabla-Swift.h`.
- `iSH/` — the Alpine sandbox kernel; `WebApp/`; `FileProvider/` — shares app-group storage with
  Files.app; `ShareExtension/`; `AgentWidget/`.
- `Diagnostics/` — `CrashReporter`, `CrashSignalHandler`, `PerfProbe`, `ResourceDiagnostics`,
  `BrowserResourceMonitor`.

## 3. Dependencies (all SwiftPM, no vendored frameworks in the app target)

| package | why |
|---|---|
| `SwiftAnthropic` (jamesrochabrun) | Anthropic transport, exact-version pinned |
| `swift-cmark` / `cmark-gfm` | Markdown |
| `SwiftMath` | LaTeX rendering |
| `RealTimeCutVADLibrary` | voice activity detection |

Native build-time deps (from `deps/`): LAME, FFmpeg (LGPL), iSH, Alpine rootfs, rclone (Go).
**No MLX, no CoreML, no FoundationModels, no llama.cpp.** Local inference is genuinely absent —
only two incidental string matches for "gguf"/"llama" in model metadata.

## 4. Patterns worth understanding (and mostly copying)

1. **Traceability tags**: **1,036 distinct `[T-…]` tags, 3,946 uses**, each pinned to a comment that
   explains *why*, often naming the crash or issue it came from (e.g. `[T-ios-listsessions-perf]`
   ×52, `[T-ctx-measure-outbound]` ×29, `[T-ios-state-publish-offmain-crash]`). This is the single
   most transferable practice, and the reason a newcomer can read an 8k-line file at all.
2. **Measure-then-justify instrumentation**: `PerfProbe` (Diagnostics) explicitly reasons about its
   own cost — per-call logging "would become a contributor to the very contention it is watching",
   so it aggregates into per-tool/per-agent buckets and emits one line per bucket per 60 s.
3. **Provider hygiene**: fallback chains, per-request budgets (`+RequestBudget`), context compaction
   (`+Compaction`), offloading of oversized tool output (`+Offloading`, with explicit
   `isOffloadedArgument` / `isOffloadReadback` provenance flags so the scanner can't mistake its own
   output for new material).
4. **Graceful degradation everywhere**: `.unsupported` provider decode, guarded config load with a
   degraded-recovery path, `LLMError` distinguishing transient/rate-limited/refused so the loop can
   retry correctly — `AgentStopReason.refusal` exists because an Anthropic safety refusal is
   deterministic, not transient.
5. **Sub agents as a first-class subsystem** (`SubAgentStore`, `SubAgentDefinition`, `[T-sub-agents-v1]`
   ×39) — agent-of-agents with their own store.

## 4b. **The key finding: the author already solved "built-in, credential-less, never-synced"**

`Providers/Voice/VoiceProvider+System.swift` ships an on-device engine (SFSpeechRecognizer +
AVSpeechSynthesizer) as a provider, and the way it is wired is a template we should copy rather than
invent around:

```swift
static let builtinProviderId = "__builtin_system_speech__"
/// Synthetic, LOCAL-ONLY ProviderInstance … WITHOUT ever being stored in
/// ProviderConfigStore.config.instances, so it is never written to the DB and never uploaded to
/// iCloud … no new ProviderType case is introduced (it never syncs, so a peer never decodes an
/// unknown type).
static let providerInstance = ProviderInstance(id: builtinProviderId, label: "System",
                                              providerType: .openAI,       // arbitrary — routing is by id
                                              credentialType: .apiKey,     // arbitrary — needs no credential
                                              isEnabled: true, createdAt: Date(timeIntervalSince1970: 0))
```
and in the store:
```swift
func instance(for id: String) -> ProviderInstance? {
    if id == SystemVoiceProvider.builtinProviderId
        || id.hasPrefix(SystemVoiceProvider.builtinProviderId + "/") {
        return SystemVoiceProvider.providerInstance
    }
    return config.instances.first { $0.id == id }
}
```

Three consequences for us:

1. **No `ProviderType` case is needed** — so none of the enum + `ProviderConfigDB` migration +
   `.unsupported`-decode risk in §7.1 applies. Routing is by id.
2. **Nothing is persisted or synced**, which is exactly the isolation property wanted.
3. **The composite-id prefix is how a built-in provider exposes several selectable models**
   (`"<sentinel>/<voice|asr>"` today; `"<sentinel>/<repo-id>"` for our models tomorrow). The picker
   already understands this shape.

So the local engine becomes two sentinel providers — `__builtin_local_mlx__` and
`__builtin_system_llm__` (Apple Intelligence) — and one settings page, rather than a new provider
family. The voice stack is also the precedent for "offline, no time/rate limits" surfacing in the UI.

## 5. What it lacks (our opportunity space)

1. **No on-device inference of any kind** — no MLX, CoreML, llama.cpp, or Apple `FoundationModels`.
   Every provider is network-backed with a credential.
2. **No credential-less / offline provider path.** `ProviderInstance` assumes an API key or OAuth and
   a base URL; there is no notion of "a model that is simply here".
3. **No Apple Intelligence integration.** iOS 27's `FoundationModels` is not imported anywhere, so
   the app cannot use the system model even where it exists.
4. **No model-lifecycle UI for local artefacts** (sizes on disk, download progress, load/unload,
   storage budget) — nothing to attach to, because nothing local shipped.
5. **Main-actor weight**: 704 `@MainActor` against 19 `actor`. Effective in a network app where work
   is I/O-bound; **hazardous for GPU work**, which must not run on the main actor.
6. **No GPU/thermal awareness** — no `thermalState` observer anywhere, no measurement of sustained
   throughput. (We measured ~20% thermal loss and a separate reboot-clearing power-state loss.)
7. **Compile-time fragility**: the type-checker timeout; 8k-line files; a body with 34 modifiers.
8. **Settings are one giant file** — `ContentView.swift` holds the settings sheet *and* the shell.

## 6. Where our prior work lands

| our work | lands as | effort |
|---|---|---|
| `LocalModelHost` / `LocalMLXProvider` (written) | `Providers/LocalMLX/`, registered via `add_sources.py`, reached through the **sentinel-id path in `instance(for:)`** — no new `ProviderType` case | S |
| **Local Inference settings area** | new `Views/Settings/LocalInferenceSettingsView.swift` + one `SettingsDestination` case + one `NavigationLink` beside "Manage Providers" | S |
| model library (`ModelStore`, Files-visible) | same view; models as `ModelEntry`s from `LLMModel.allLocalMLX` | S |
| turn-boundary prompt cache | inside `LocalModelHost` (already written) | — |
| effort → thinking/loops | extend `ThinkingRule` resolution for the local type; `ThinkingLevel` already exists | M |
| `decide` / classify | a tool in `+ToolDefinitions` + optionally a Shortcut; needs a fast path that skips the agent loop | M |
| inference benchmarks | `Diagnostics/PerfProbe` idioms + `AgentRequestTrace`; our batteries stay in LoopLab | S |
| memory-entitlement requirement | already handled in signing; the settings page should *show* granted memory | S |
| Shortcuts actions | `Agent/Intents/` already has 15 files — extend rather than build anew | S |

## 7. Traps to avoid (each already cost us time once)

1. **Adding a provider *type* is not local** — enum + both factories + `allModels` + DB migration +
   picker. **Avoidable entirely** via the sentinel-id pattern in §4b; if a real enum case is ever
   needed, the `.unsupported` decode fallback must be respected or an older install drops the config.
2. **New files must be registered in the *app target's* Sources phase** (`E51000041`); a file added
   to the first `PBXSourcesBuildPhase` compiles nothing ("cannot find X in scope").
3. **Don't run MLX on the main actor.** The provider protocol is called from `@MainActor` code; keep
   generation inside an `actor` and hand back an `AsyncThrowingStream`.
4. **Extensions can't ship** on a free Apple ID (each needs an App ID); keep them out of the sideload build.
5. **The app group id is derived by the signer**, with a team-id suffix — resolve it at runtime
   (`AppGroupResolver`), never hardcode.
6. **Any local model must degrade honestly**: a memory/thermal failure must surface as an `LLMError`
   the fallback chain understands, or the agent loop will retry forever.

## 8. Verdict

Well-engineered for what it is — a network-first agent with strong instrumentation, disciplined
traceability and genuine degradation paths. It does **not** need rescuing; it needs one new subsystem
added the way the author would: a credential-less local provider, a settings area that manages model
artefacts, and instrumentation that keeps GPU work off the main actor and reports honest timings.

The gap our work fills is precise: **everything the app measures is about tokens and context, nothing
is about the hardware.** On a phone with a fixed memory ceiling and a thermal budget, that is the
missing axis.
