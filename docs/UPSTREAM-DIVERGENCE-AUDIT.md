# Divergence audit — our engine vs upstream `mlx-swift-lm` guidance

Source of truth: `skills/mlx-swift-lm/` shipped *inside* `mlx-swift-lm` (pulled from tag 3.32.3 into
`docs/upstream-skills/`). Apple authors agent-facing reference docs for the exact integration we are doing.
Anything below marked "verify" needs a look at our code before the next build.

## 1. Admission control — we hand-rolled what upstream ships (at our pin)

| Our code | Upstream, available at 3.32.3 | Action |
|---|---|---|
| `LocalModelStore.runCost(for:contextTokens:kvBits:)` — `info.bytes + kv×scale + 320 MB` guess | `WiredMemoryPolicies.swift` / `WiredMemoryUtils.swift`: `WiredSumPolicy(cap:)`, `WiredMaxPolicy()`, `WiredFixedPolicy(limit:)`, `WiredBudgetPolicy(baseBytes:cap:)`; `policy.ticket(size:kind:)` with `.active` / `.reservation`; `modelContainer.generate(input:parameters:wiredMemoryTicket:)` | **Adopt.** Replace the heuristic with a measured budget. |
| Our own OOM refusal in `LocalModelHost.load` | `WiredMemoryUtils.tune(context:tokenCount:parameters:)` → `measurement.weightBytes`, `.workspaceBytes`, `.kvBytes` | **Adopt.** Measure once per model+context instead of assuming 320 MB of working set. |

Why it matters: our estimate is a constant guess; theirs is a measurement. The 4B fit warning we show the
user is currently derived from arithmetic.

## 2. Model registration — the path to "no app code change per model"

`ModelTypeRegistry` (at our pin) exposes:

```swift
public func registerModelType(type: String, creator: @escaping (Data) throws -> T)
public func registerModelType(type: String, matches: @escaping (Data) -> Bool, creator: ...)
public func createModel(configuration: Data, modelType: String) throws -> sending T
public func contains(_ modelType: String) -> Bool
```

`matches:` is **config-conditional** — a registry entry is selected by inspecting the checkpoint's own
`config.json`. That is the mechanism for the user's requirement that downloading a new architecture must not
require code changes: register at runtime against config data, rather than adding an enum case per family.
For embedders specifically, `MLXEmbedders` also has `ModelConfiguration.register(configurations:)` (a
runtime registry of model configurations) — see `references/embeddings.md`.

## 3. KV precision — a real trap, and a reason our lever underdelivered

From `references/kv-cache.md`:

- `RotatingKVCache` is the **sliding-window** cache; `RotatingKVCache.toQuantized()` is **not implemented and
  will `fatalError()`**. Never force quantization onto a rotating cache.
- The plan builder only quantizes `.simple` leaves (`maybeAffineQuantizeKVCache` guards
  `case .simple(let simple)` and otherwise returns the cache untouched).

Consequence for us: **on a hybrid model (Qwen3.5-4B has sliding-window layers), our KV precision setting
only applies to the non-sliding layers — silently.** That is a large part of why 8-bit K/V did not deliver
the expected saving on the 4B, and why "full precision" looked competitive. Nothing crashes (the plan skips
those leaves), but the UI claims a saving that is not applied uniformly.

Also noted downstream: `QuantizedKVCache.update()` has a fatalError path if a quantized cache is updated the
wrong way (kv-cache.md line ~322) — worth knowing before we touch cache code.

Action: state the truth in the UI (which layers can be quantized for this model), and treat `maxKVSize`
(manual context management) as the lever for sliding-window models, not `kvBits`.

## 4. Prompt cache — upstream has persistence we ignored

`KVCacheStatus` / `cacheStatus()`, and `savePromptCache` / `loadPromptCache` exist upstream. Our session
pool (`maxLiveSessions = 2`, keyed by `modelId|thinking|FNV1a(systemPrompt)`) reinvented cross-request
retention; the persisted-cache API also survives app restarts, which ours does not. Verify before extending.

## 5. Tool calling — check against `references/tool-calling.md`

We forward schemas as `ToolSpec` and let the model template render them, then execute via the app's agent
loop. Upstream documents the supported dispatch shapes (*verify* that our "no `toolDispatch` ⇒ caller
executes" assumption is the documented one, not an accident of the pinned version).

## 6. Embeddings — the shape we should copy

`references/embeddings.md`: `EmbedderModelFactory.shared.loadContainer(from:using:configuration:)` →
`EmbedderModelContainer.perform { context in context.tokenizer / context.model / context.pooling }`,
`ModelConfiguration(id:)` for a specific checkpoint, `ModelConfiguration.models` for the built-in registry,
`ModelConfiguration.register(configurations:)` for our own. Pooling is a first-class choice
(mean / cls / first / last / max / none). Task prefixes are **not** injected by the library — the caller
must, which means prefix handling belongs in our model metadata, not in code per model.

## 7. Pin drift

Our pin is `3.32.3` (2026-09-30), which **predates** the bidirectional-attention fix for Gemma embedders
(`#654`, merged 2026-10-07). Any Gemma embedding computed on this pin is causally masked and therefore
wrong. `#580` (load components on demand) merged 2026-10-12 — that is what makes a text-only load of a
multimodal checkpoint possible without shipping the media towers. Bump the pin before any embedder work.

## 8. Bonus: upstream ships skills, and so do we

`skills/README.md`, `skills/mlx-swift-lm/SKILL.md` + 13 references. The same convention this app uses for
`/var/minis/skills/`. Worth adopting as a habit: when we implement a subsystem against a library, keep the
library's own skill docs in the repo and note divergences here.
