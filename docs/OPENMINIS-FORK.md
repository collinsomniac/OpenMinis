# OpenMinis fork — plan (2026-10-10)

Fork: **github.com/collinsomniac/OpenMinis** (from OpenMinis/OpenMinis, GPL-3.0).
Goal: make OpenMinis our daily-driver base, run its agent on the phone's GPU through our MLX engine,
and graft LoopLab's improvements in. Function before aesthetics.

## 1. What OpenMinis is, decomposed

| area | size (Swift) | what it does | LoopLab equivalent |
|---|---|---|---|
| `Agent/` | ~5.0 MB | agent loop, chat view-model, tools (file/shell/memory/browser), compaction, fallback, sub-agents, background tasks, Shortcuts intents | Chat tab (single-turn, no tools), 7 Shortcuts actions |
| `Views/` | ~3.6 MB | the full SwiftUI app | 5 tabs |
| `Providers/` | ~1.8 MB | 9 cloud provider families behind two protocols; model groups and routing; thinking-level rules; voice | — (we are the provider) |
| `iSH/`, `NativeOffloads/` | ~0.4 MB | the Linux sandbox | — |
| extensions | | Share, File Provider, Widget | — |
| `MinisTests` | ~2.3 MB | tests | batteries on the desktop |

**What OpenMinis lacks entirely: on-device inference.** No MLX, no Core ML, no local provider.

## 2. The integration point (one seam)

All model traffic goes through two protocols in `src/ios/Providers/`:

```swift
protocol LLMProvider   { func streamMessage(messages:systemPrompt:maxTokens:temperature:) -> AsyncThrowingStream<LLMStreamChunk, Error> }
protocol AgentProvider { func streamAgentMessageClamped(messages:systemPrompt:tools:maxTokens:thinkingLevel:) -> AsyncThrowingStream<AgentStreamEvent, Error> }
```

and providers are constructed in exactly two switches over `ProviderType`:
`LLMProviderFactory.makeProvider` and `AIChatViewModel.makeAgentProvider`.

So a local engine is: **one new `ProviderType` case (`.localMLX`), one `LocalMLXProvider` +
`LocalMLXAgentProvider` pair, and one line in each switch.** Nothing else in the agent loop needs to
know the model is local — that is the whole point of their abstraction, and it is a good one.

`AgentStreamEvent` maps cleanly onto MLX generation: `.textDelta` ← token chunks, `.thinkingDelta` ←
`<think>` content, `.usage` ← `GenerateCompletionInfo`, `.toolCallComplete` ← parsed tool calls
(mlx-swift-lm has a tool-call parser and `ToolSpec`), `.done(stopReason:)` ← end/max-tokens.

## 3. What we graft from LoopLab

| LoopLab piece | lands in OpenMinis as |
|---|---|
| mlx-swift-lm fork (Ouro, loop control) | SwiftPM dependency of the app target |
| `ModelHost` (load, generate, memory policy) | `LocalMLX/LocalModelHost.swift` — one model resident at a time |
| `ModelStore` (on-device library in Files) | `LocalMLX/LocalModelStore.swift`; models appear in the existing model picker |
| prompt-cache reuse (`ChatSession`) | per-session KV reuse in `LocalMLXAgentProvider` — the agent loop re-sends the whole transcript every turn, so this is the biggest single win |
| effort → thinking/loops mapping | maps onto OpenMinis' existing `ThinkingLevel` |
| `decide` / Score Options | a `decide` tool and Shortcuts action |
| memory entitlement | added to the main app's entitlements (required — ~6 GB vs ~3.25 GB) |
| benchmarks / queue | stay in LoopLab, which remains the lab |

## 4. Build and install — the constraints that shape step 1

- **No Mac.** OpenMinis has **no CI workflow** in its repo; it is built locally on macOS. We add a
  GitHub Actions workflow on the `xcode-27` runner, as for LoopLab.
- **Heavy native deps**: LAME, FFmpeg (LGPL), iSH, an Alpine rootfs, rclone (Go). First build
  30–60 min. Cached in CI after the first run.
- **Free Apple ID**: ~10 App IDs per week, 3 active apps. OpenMinis has 4 targets (app + Share +
  File Provider + Widget). **Step 1 builds the main app only** and strips the extensions, so one App ID.
- **Bundle id**: change `com.openminis.app` → `io.github.collinsomniac.openminis` so it installs
  **alongside** the App Store Minis rather than replacing it.
- **App group / iCloud / push / keychain-sharing entitlements** in the stock project cannot be granted
  to a free team; the CI signs ad hoc with a reduced entitlement set (memory limit + app group only).
- **Deployment target** is already 26.2 for the app; Swift 6.0 for the app target.
- **Install**: the existing cable-free pipeline (`loopdeploy` → `pack_ipa.py` → `install_signed.py`)
  works unchanged for any IPA.
- **License**: GPL-3.0. The fork stays public; LoopLab code merged into it becomes GPL (fine — our
  repos are public; we should add a licence to LoopLab before merging).

## 5. Phases

### Phase 1 — DONE (2026-10-10)
Build `openminis-6` built, signed and installed **over Tailscale, no cable**:
`io.github.collinsomniac.openminis.FRJQU6T5U5 v1.14 (6)`, sitting alongside the App Store
`com.openminis.app` v1.14 (27) and LoopLab v0.1.25. One App ID, no extensions.
Build time: ~12 min with the native-deps cache warm (first run ~40 min for LAME/FFmpeg/iSH/rootfs/rclone).

Three fixes were needed, none of them in OpenMinis' logic:
1. **`lld`** — Homebrew split it out of `llvm`; the iSH VDSO links with `-fuse-ld=lld`.
2. **`prepare_sideload.py`** — main app only (the three embedded extensions each need their own
   App ID on a free account), own bundle id, deployment targets aligned on 26.2 (some were 16.x while
   the code uses 17.5+ API), entitlements reduced to `increased-memory-limit`; isideload then adds an
   application group itself during signing.
3. **A type-checker timeout in `Views/ContentView.swift`** — a 34-modifier view body in an 8,783-line
   file. `performInitialLoad()` extraction and the CI solver-threshold flag were both insufficient;
   splitting the body into three chained stages (`bodyStage1/2`) fixed it. This is the same class of
   problem Apple's iOS 27 `ContentBuilder` work targets.

### Phase 2 — next: the local engine
`LocalMLXProvider.swift` / `LocalModelHost.swift` are written (outside the repo, in
`/var/minis/workspace/openminis-staging/LocalMLX/`) and need: the MLX SwiftPM dependency, the two
files registered in the Minis target, a `.localMLX` case in `ProviderType`, and one line in each of
the two provider switches. The cache policy in `LocalModelHost` already implements the
turn-boundary checkpoint that `docs/RECON-2026-10-10.md` §7 ranks first.

### Original plan

1. **Builds and installs, unmodified** (except bundle id, extensions stripped, entitlements reduced).
   Proves the toolchain. Risk: the native-deps build on CI.
2. **LocalMLX provider, text only.** New provider type, model picker shows on-device models, agent
   loop streams from the phone's GPU. Prompt-cache reuse from day one.
3. **Tools on-device.** Tool-call parsing for local models (Qwen family emits `<tool_call>` JSON);
   start with the read-only tools. Small local models with large tool schemas are a known weak spot,
   so measure before enabling everything.
4. **Routing.** Use the existing model-group router: local for cheap steps (classify, summarise tool
   output, short code), cloud for planning — the cost-per-task win.
5. **Graft the rest**: Shortcuts actions, decide/score, effort/loops, library management UI.
