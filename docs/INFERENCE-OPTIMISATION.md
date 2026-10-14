# Inference optimisation — why it is this fast, and what can change it

Working notes for the pass after build 26. Every number here is either measured on this device (named) or
arithmetic from the models' own config, and every mechanism is one the library already implements — no
private patches, no per-model special cases, so the same improvements apply to whatever MLX model is
dropped into the library next.

---

## 1. The arithmetic that explains 40 tok/s

Decode is bandwidth-bound: each generated token re-reads the whole model **and the whole KV cache**.

Per context token of KV, for a plain attention stack:

```
kv_bytes_per_context_token = layers × 2 (K,V) × kv_heads × head_dim × bytes_per_element
```

| model | attention layers | kv heads | head dim | KV / context token (fp16) |
|---|---|---|---|---|
| Qwen3-0.6B-4bit | 28 | 8 | 128 | **112 KB** |
| Qwen3.5-4B-8bit | 8 of 32 (the rest are linear attention with fixed state) | 4 | 256 | **32 KB** |

Bytes read per decoded token, on this device's measured ~56 GB/s:

| scenario | weights | KV | total | ceiling |
|---|---|---|---|---|
| Qwen3-0.6B, ~200-token prompt (LoopLab's bench) | 335 MB | 22 MB | 0.36 GB | **~160 tok/s** ← measured 164.5 |
| Qwen3-0.6B, app's ~6.6k-token prompt | 335 MB | 740 MB | 1.08 GB | **~52 tok/s** ← user measured 40 |
| Qwen3-0.6B, 6.6k prompt, 8-bit KV | 335 MB | 370 MB | 0.71 GB | ~79 tok/s |
| Qwen3-0.6B, 6.6k prompt, 4-bit KV | 335 MB | 185 MB | 0.52 GB | ~108 tok/s |
| Qwen3.5-4B-8bit, 6.6k prompt | 5.14 GB | 216 MB | 5.36 GB | **~10 tok/s** |
| Qwen3.5-4B-**4bit**, 6.6k prompt | 2.9 GB | 216 MB | 3.12 GB | ~18–25 tok/s ← 4-bit measured 25.3 |

Two conclusions follow, and they are different for the two models:

- **The 0.6B is not slow because of the model — it is slow because of the conversation.** Its weights cost
  335 MB per token; the app's system prompt costs 740 MB per token in KV reads. The "3-digit tok/s" goal
  and this app's prompt length are in direct tension, and no sampler change can resolve it.
- **The 4B is weight-bound.** Its KV is small (only 8 of 32 layers keep a growing cache), so the lever is
  **quantisation of the weights**, not the cache: 8-bit ≈ 10 tok/s, 4-bit ≈ 20–25 tok/s for the same
  model. The 8-bit build is also 5.14 GB against a ~6.4 GB ceiling — which is what made it a crash risk.

This is also why the earlier "it got slow" episode had nothing to do with the app: measurement conditions
(prompt length, thermal state, Low Power Mode, device uptime) dominate, so they are now reported in the UI
rather than inferred.

## 2. What is worth doing, in order of effect on decode rate

### 2.1 KV cache precision (largest lever at long context)
`GenerateParameters.kvBits` selects an affine KV cache plan
(`Evaluate.swift :: kvCachePlan()` → `KVCacheConfiguration.Strategy.affine(AffineKVCacheConfiguration(
bits:groupSize:compressionStart:))`; supported widths `[2,3,4,5,6,8]`). `quantizedKVStart` is
`compressionStart`: **K/V stays full precision for the first N tokens**, which matters because our own
measurements showed quantised attention is a few percent *slower* at 192 tokens — so a short chat should
pay nothing while a long one wins. Wiring added in this pass: a Settings control (Full / 8-bit /
8-bit after 2k / 4-bit after 2k) applied to the generation parameters; the library compares cache plans
and rebuilds the cache when the choice changes, so switching mid-conversation is safe.

Also available and not yet used: `kvScheme` selects *named* schemes beyond affine —
`KVCacheConfiguration.Strategy.turboQuant(TurboQuantKVCacheConfiguration)` and `.varianceNormalized(...)`.
Those are likely better quality-per-bit than affine at 4-bit and 2-bit; worth benchmarking before
defaulting to affine.

### 2.2 Bounded KV with a preserved prefix
`KVCacheConfiguration.Capacity(maxTokens:preservedPrefixTokens:)` bounds the cache and *pins the first N
tokens*. For an agent whose system prompt is thousands of tokens and whose conversations are long, this
bounds both memory and per-token reads without discarding the prompt. `maxKVSize` on
`GenerateParameters` is the legacy spelling. Models that declare a native sliding window already use
`RotatingKVCache` internally.

### 2.3 Prompt length
Fewer prompt tokens ⇒ proportionally fewer KV bytes to read per token. This is the honest reason a
"compact prompt for on-device models" changes speed by a factor, not a percent — and it is the one lever
that trades capability rather than precision.

### 2.4 Prefix reuse
Helps time-to-first-token, not decode rate: it avoids re-prefilling, but the KV still gets read per token.
The library can even persist a prompt cache (`savePromptCache` / `loadPromptCache` in `KVCache.swift`),
which would let the app's large system prompt be prefilled once ever rather than once per launch.

### 2.5 Weights (the 4B's lever)
4-bit instead of 8-bit ≈ half the bytes ⇒ ~2× decode. Nothing in the app can beat the
`tok/s ≈ 56 ÷ GB-per-token` relation; the choice of quantisation sets it.

## 3. How others solve this (and what transfers)

| source | technique | transferable here? |
|---|---|---|
| **DeepSeek-V4.1-Flash** (KV-cache compression; our earlier review in `/var/minis/shared/deepseek-ocr-v41/`) | FP4 E2M1 global KV with per-16-channel E4M3 scales, **no second-level global scale**, quantise **after RoPE**, dequantise before attention (storage not FLOPs); SWA bounded replay; sparse indexing; 890 B/token | The *shape* of the idea is exactly §2.1 — the datacenter version of `kvBits`. We can't do the sparse indexer, but "quantise K/V, keep the scales per group, do it after RoPE" is what MLX's affine KV cache already is. Progress: 890 B/token is ~2 orders below our 112 KB/token. |
| **DeepSeek-OCR** | optical context compression (render text as an image, ~10× fewer tokens) | The other axis: fewer *tokens* rather than fewer bytes per token. Not applicable to conversation history; the standing critique (arXiv 2512.03643 — "optical compression is just (bad) autoencoding") is why it is not a default. |
| **llama.cpp** | `-ctk q8_0 -ctv q8_0` KV quantisation; flash attention; sliding-window KV; prompt caching | Directly analogous to §2.1/§2.2 and evidence that K/V quantisation is standard practice, not an experiment. |
| **vLLM / MLX server** | paged attention, prefix caching, continuous batching | Paging is not applicable to a single-sequence phone workload; prefix caching maps to §2.4. |
| **ninfer / Strata** (our recon) | checkpoints at *semantic* boundaries; message-boundary cache | Already reflected in the reuse policy (`streamDetails` append-only). |
| **MTP speculative decoding** (`MTPDrafterModelFactory`, `Qwen35TextMTPRegistration` — Qwen3.5 supported) | draft heads in the checkpoint itself, no separate draft model | Blocked on the artifact: the mlx-community conversion **strips** the MTP tensors (declared `mtp_num_hidden_layers: 1`, no `mtp*` weights in the index). A conversion that keeps them would make this available generically. |

## 4. Claims to test in the next build

1. **KV precision, 0.6B, real conversation (~6.6k prompt):** full vs 8-bit-after-2k vs 4-bit-after-2k.
   Prediction: ~50 → ~79 → ~105 tok/s. If it does not move, my bandwidth model is wrong and the bottleneck
   is elsewhere (then look at the logits projection and the sampler).
2. **Prompt length:** Measure with the system prompt vs the short benchmark prompt. Prediction: ~52 vs
   ~160 tok/s on the same model, same session.
3. **The 4B:** 4-bit build vs 8-bit, same prompt. Prediction: ~2× on decode, and the memory-fit warning
   disappears.
4. **TurboQuant / varianceNormalized KV at 4-bit** vs affine 4-bit: quality at equal bytes.
5. **Reused tokens:** after two turns, `Last turn → Prompt` should show reused > 0. If it stays 0, cache
   reuse is still not engaging and that is the next thread (it was 0 in the user's screenshot).

## 5. Tool calling and vision parity (the pass after)

Both should go through the library and the app's existing agent loop — no parallel implementation:

- **Schemas**: `AgentToolDefinition` → MLX `ToolSpec` (= `[String: any Sendable]`, OpenAI-shaped) on
  `ChatSession(tools:)` / the `generate(…tools:)` path. The library renders them into the model's own
  template.
- **Parsing**: `Generation.toolCall(ToolCall)` (with `ToolCall.function.name` and
  `arguments: [String: JSONValue]`) → the app's existing `AgentStreamEvent.toolCallComplete(id:name:args:)`,
  which the agent loop already knows how to execute. `ToolCallFormat.inferred(fromChatTemplate:)` picks
  the right parser *from the model's own template*, which is what keeps this generic instead of one branch
  per model family.
- **Vision**: already wired (`modalityOverride: .vision` + `Chat.Message.user(_:images:)`); the open
  question is whether a mixed text/vision turn reuses the cache well — the library reports
  `carriesPreparedMedia` / `canSplitPreparedMedia` on its prompt-cache input, so it has an answer we
  should read rather than invent.
- **Also worth checking**: `ToolCallPolicy` (what the library does with a tool call it considers
  unauthorised or mis-parsed) and `rejectedToolCallCount` / `recoveredToolCallCount` in
  `GenerateCompletionInfo` — telemetry for exactly the failure mode a small model exhibits.
