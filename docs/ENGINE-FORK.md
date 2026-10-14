# Owning the engine: what compiling our own MLX buys, and what it would take

Answers three questions: what "the conversion strips the MTP tensors" means and whether it is fixable;
whether building our own engine fork is worth it; and where, concretely, a fork would beat the vanilla
library by enough to be defensible. Sources are the exact versions we ship — mlx-swift-lm **3.32.3**,
mlx-swift **0.32.3**, and the MLX C++/Metal core it pins (`ml-explore/mlx@1f8e74e3`) — plus the Hub
metadata of the checkpoints. Predictions come from `tools/decode_model.py`, a bandwidth model calibrated
against LoopLab measurements on this phone.

---

## 1. What we compile today, and what we don't

Every build compiles the whole stack from source: SwiftPM fetches mlx-swift-lm (Swift), mlx-swift
(Swift + the C++ core as a submodule + its **132 Metal kernel files**) and builds them for the phone. So
the "low-level access" is not hypothetical — **we already build the kernels; we just don't own them.**
Owning them means pointing SwiftPM at our fork instead of upstream. LoopLab already does exactly that for
mlx-swift-lm (branch `ouro-3.32.3`, adding looped-model support), so the mechanics are proven.

| layer | language | what lives there | can we change it? |
|---|---|---|---|
| model zoo, sampling, ChatSession, KV policy | Swift (mlx-swift-lm) | everything we've touched so far | yes — fork, already done once |
| array API, `MLXFast` | Swift (mlx-swift) | bindings, fast-path ops | yes — fork mlx-swift |
| ops, graph, scheduler | C++ (mlx) | lazy evaluation, fusion, buffer cache | yes — fork mlx, pin the submodule |
| kernels | Metal (mlx/backend/metal/kernels) | quantized matmul, SDPA, RoPE, softmax, sort | yes — and this is where the big wins are |

## 2. MTP: what the problem is, and that it is solvable

**Multi-Token Prediction (MTP).** Qwen3.5 was trained with an extra small "next-next-token" head (one
transformer layer plus a projection). At inference it drafts a few tokens cheaply, and the full model
verifies them in one pass. Accepted tokens are free; a rejected draft costs only the head. The output
distribution is unchanged — it's lossless.

**Where the tensors went.** The official checkpoint **has** the head:

| repo | files | MTP tensors |
|---|---|---|
| `Qwen/Qwen3.5-4B` (official, bf16, 9.34 GB) | 2 shards | **15** (`mtp.fc`, `mtp.layers.0.{self_attn,mlp,norms}`, `mtp.norm`, `mtp.pre_fc_norm_{embedding,hidden}`) |
| `mlx-community/Qwen3.5-4B-MLX-8bit` (the one installed) | 1 shard, 5.16 GB | **0** |
| `mlx-community/Qwen3.5-4B-MLX-4bit` | 1 shard, 3.06 GB | **0** |
| `mlx-community/Qwen3.5-4B-OptiQ-4bit` | 4.04 GB | 0 in the main index, but ships `optiq/mtp.safetensors` (86.7 MB) **as a separate file** |

So mlx-community's converter discards the head, because the text model doesn't need it to run.

**The library already supports it.** `Libraries/MLXLLM/Models/Qwen35MTP.swift` defines
`Qwen35MTPDraftModel`, registered by `Qwen35TextMTPRegistration` for `qwen3_5_text`, `qwen3_5_mtp`,
`qwen3_5`, `qwen3_5_moe`. It reuses the target's embedding and LM head (`targetEmbeddingAndHead`), and
`qwenMTPSanitizeWeights` knows the `mtp.*` key layout (with a `preconvertedNorms` switch for checkpoints
that already shifted the RMSNorm weights). The entry point is
`generate(input:cache:parameters:context:mtpDrafter:blockSize:)` in `Evaluate.swift`
(`MTPSpeculativeTokenIterator`, default `blockSize = 4` = 3 drafted + 1 bonus).

**So yes, it is solvable, three ways (cheapest first):**

1. **Use a conversion that keeps the head.** The OptiQ repo ships it as `optiq/mtp.safetensors`. Point
   `MTPDrafterModelFactory` at those 86.7 MB and the app gains MTP **with no fork at all**, only loader
   plumbing. *Cost: hours. Risk: OptiQ is a different quantization recipe — benchmark its quality.*
2. **Extract it ourselves.** Pull the 15 `mtp.*` tensors from the official bf16 checkpoint, quantize them
   (or keep them bf16 — they are ~1/30th of the model), and save `mtp.safetensors` next to any MLX
   conversion. This runs once on the desktop, CPU-only, a few minutes. It's a tool rather than a fork,
   and it works for any Qwen3.5 size.
3. **Own the converter.** Make our model-download path produce "model + MTP head" for every model that
   declares `mtp_num_hidden_layers > 0`.

**Is MTP worth it on this phone?** It depends on what limits a model.

- **The 4B is weight-bound** (`decode_model.py`: ~19 tok/s at 4-bit, flat across context). Speculation
  is the one lever that beats a weight-bound ceiling, because verifying 4 tokens costs about the same
  weight read as generating 1. LoopLab measured MLX's batched verify at **1.31–1.42×** with a 0.6B
  *separate* draft model. An MTP head is ~30× cheaper than that draft model and shares the target's
  hidden state, so its acceptance should be higher too. Expect roughly **1.5–2.2× on the 4B**, i.e.
  ~19 → 30–40 tok/s at 4-bit. That's the largest single speedup available for the 4B.
- **The 0.6B is KV-bound at long context**, so the KV-cache work in §3 matters more for it, and it has
  no MTP head anyway.

**The catch only a fork fixes.** The `MTPSpeculativeTokenIterator` documentation says that if the target
"stops emitting drafter state — **a KV cache that quantizes mid-stream**, say — the iterator logs once,
reports `passthroughReason`, and finishes with ordinary single-token generation." **Vanilla MLX makes
MTP and quantized KV mutually exclusive.** These are exactly our two biggest levers, one for each model
class. Making them compose (the drafter reads quantized KV, or keeps its single layer's own fp16 cache)
is engine work, and it is the kind of change that justifies owning the fork.

There's also a third family worth knowing about: **DFlash** (`z-lab/Qwen3.5-4B-DFlash`, arXiv
2602.06036), a 6-layer block-*diffusion* drafter that proposes 16 tokens in parallel, conditioned on
hidden states from target layers [1,5,9,…,29]. It reports large server-side speedups, but at 1.27 GB
it's ~40% of a 4-bit 4B and has no MLX/Swift implementation (SGLang/vLLM only). It's a research option
for later, not a near-term one.

## 3. Where a fork beats vanilla by enough to matter

### 3.1 A fused quantized-KV attention kernel — the defensible one

**What vanilla does.** MLX's fast attention for decode, `sdpa_vector` (`kernels/sdpa_vector.h`), is
templated on a **single element type `T`** for queries, keys and values. There's no quantized variant.
With quantized KV, mlx-swift-lm instead calls `quantizedScaledDotProductAttention` (`KVCache.swift`):
`quantizedMM(q, Kq)` → **materialize the full score matrix** → mask via `where` → softmax →
`quantizedMM(p, Vq)`. So it reads half the K/V bytes, but writes and re-reads an `[heads × context]`
fp32 matrix through several separate kernels, once per layer, per token.

**What the model predicts** (Qwen3-0.6B-4bit, tok/s):

| context | fp16 fused (today's default) | 8-bit, vanilla unfused | 4-bit, vanilla unfused | 8-bit **fused** | 4-bit **fused** |
|---|---|---|---|---|---|
| 256 | 154 | 158 | 162 | 160 | 163 |
| 2,048 | 98 | 116 | 132 | 122 | 140 |
| **6,600** (this app's prompt) | **51** | 69 | 90 | 76 | **102** |
| 16,000 | 26 | 38 | 55 | 43 | 66 |
| 32,000 | 14 | 21 | 33 | 25 | 41 |

Two readings:

- **Vanilla KV quantization is already a real win** (51 → 69/90 at 6.6k). That's what build 28's KV
  setting turns on, so it should be measured *before* anything is forked, and it's worth having either way.
- **Fusion adds a further ~10–25%** on top, growing with context. The model is conservative here: it
  ignores the per-kernel launch and synchronization cost of the unfused chain (five dispatches per
  layer × 28 layers), which on a phone GPU is often the larger cost. The honest claim is "≥10–25%,
  possibly much more", and it needs a measurement.

**The kernel itself** is a narrow, well-specified change: a variant of `sdpa_vector` (and its 2-pass form
for long context) that takes packed K/V plus per-group scales and biases, dequantizes inside the
`qk_per_thread`/`v_per_thread` loops, and keeps scores in threadgroup memory as the fp16 kernel already
does. MLX already has the dequant primitives it needs (`quantized_utils.h`, `fp_quantized.h`). This is
the same idea DeepSeek-V4.1-Flash applies at datacenter scale (FP4 K/V, per-group scales, dequantize
inside attention), and llama.cpp ships it as quantized-KV flash attention.

### 3.2 MTP × quantized KV, composed — the other defensible one
§2's catch. It's the only way to stack the 4B's best lever (MTP) with the long-context lever (quantized KV).
This one is Swift-level (iterator and drafter-state plumbing), not a kernel.

### 3.3 Persisted prefix cache for the system prompt
`savePromptCache` / `loadPromptCache` already exist. Prefilling this app's ~6.6k-token system prompt once
per *install* rather than once per launch is an app-level change and needs no fork. It cuts TTFT, not
decode rate.

### 3.4 What not to fork for
- **Sampling.** The top-p cost was our configuration, not a library limitation.
- **Model support.** Models arrive upstream continuously. A fork that diverges in model code would turn
  every update into a merge, so the fork should stay *narrow*: kernels plus a few seams.
- **NAX/tensor-unit kernels** (`*_nax.metal`). Upstream is actively working on them; anything we wrote
  there would be obsolete within months.

## 4. Recommendation

**Fork, narrowly, and measure first.**

1. **Now, vanilla:** install build 28 and measure KV precision on the 0.6B at real context (prediction:
   51 → ~69 at 8-bit, → ~90 at 4-bit). If those numbers appear, the bandwidth model is right and every
   prediction below is grounded.
2. **Now, no fork:** MTP for Qwen3.5 via an MTP head file (OptiQ's, or one we extract from the official
   checkpoint). Prediction: 4B at 4-bit, ~19 → 30–40 tok/s.
3. **Fork mlx (C++/Metal):** the fused quantized-KV `sdpa_vector` variant, with a benchmark in LoopLab
   comparing it against vanilla unfused at 2k/6.6k/16k/32k context. **Bar for keeping it: ≥15% over
   vanilla quantized KV at 6.6k with identical outputs** (deterministic greedy decode, token-for-token).
4. **Fork mlx-swift-lm:** MTP that survives quantized KV.
5. **Upstream what works.** A fused quantized-KV kernel is useful to everyone. Contributing it back
   shrinks our fork, and that's what keeps maintenance affordable.

Owning the stack is defensible when the fork stays a short list of measured, generic improvements: none
of the above is specific to one model family. Every MLX model with attention benefits from §3.1, and
every MTP-trained model benefits from §2/§3.2. Model-specific patches would not be defensible, and
neither would rewriting what upstream already does well.
