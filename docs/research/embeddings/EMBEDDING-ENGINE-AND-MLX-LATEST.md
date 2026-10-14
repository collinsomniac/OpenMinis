# The embedding engine as a low-level capability: MLX state, EmbeddingGemma 2 / Harrier provider requirements, and the integration surfaces

**Research date:** 2026-10-12 (America/Phoenix). All repository facts below were read from the live sources during this session: `ml-explore/mlx-swift-lm` cloned and checked out at `main`, the app source at `/var/minis/workspace/openminis`, the iSH fork at `deps/ish`, and the Hugging Face model repositories fetched live (`config.json`, `1_Pooling/config.json`, `modules.json`, `sentence_bert_config.json`, `config_sentence_transformers.json`, `README.md`).

**What this document is:** an extension of `EMBEDDING-GEMMA-2.md` and `EMBEDDING-INTEGRATION.md`, not a restatement. Those two cover the model facts and the on-device index/Shortcuts design. This adds (1) the exact MLX Swift delta since our pin, (2) the provider-surface requirements for EmbeddingGemma 2 and Harrier **with the owner of each requirement named**, (3) a model-family / execution-path analysis, and (4) a concrete design for embeddings-as-a-capability across MCP, the in-guest CLI, the agent tool registry, App Intents, and skills — with file and symbol names from our codebase.

**Our stack, as given and as verified:** iOS 27 app; MLX Swift via SwiftPM; `mlx-swift-lm` pinned at **3.32.3**; `mlx-swift` 0.32.3. `3.32.3` is genuinely the newest *release* — `get_latest_release` on `ml-explore/mlx-swift-lm` returns `3.32.3`, published **2026-09-30T20:38:34Z**, and the newest tag in the clone is `3.32.3` (tag commit `3b339ad`, 2026-09-30). Chat LLMs run through `MLXLLM`/`MLXLMCommon` on-device; embedding models are being added as a second kind of local model.

---

## 0. Bottom line (the five things that change decisions)

1. **Nothing on `main` gives us EmbeddingGemma 2.** No `embedding_gemma2` / `embedding_gemma2_text` key exists in `EmbedderTypeRegistry` at `main`, and `LLMModelFactory`'s model-type list is **identical** between `3.32.3` and `main` (62 keys, set-diff empty). PR **#684 is still open** (state `open`, `merged: false`, `mergeable_state: blocked`, 11 files, +3,955/−610, last updated 2026-10-12T19:41Z).
2. **Both Harrier variants load today on 3.32.3 with zero new compiled code.** Verified from the live `config.json`: `microsoft/harrier-oss-v1-270m` is `model_type: "gemma3_text"` and `microsoft/harrier-oss-v1-0.6b` is `model_type: "qwen3"` — both already keys in `EmbedderTypeRegistry.shared`. Harrier is also **decoder-only with last-token pooling** (not a bidirectional encoder), so the #654 bidirectional bug does not apply to it.
3. **Two merged PRs are prerequisites for any Gemma-family embedder, and both landed after the 3.32.3 cut:** **#654** (bidirectional attention in `EmbeddingGemma`, merged **2026-10-07T16:18:25Z**) and **#580** (load model components on demand, merged **2026-10-12T16:09:55Z**). On `3.32.3`, EmbeddingGemma-1 embeddings were causally masked; the PR's own measurement is cosine **0.45–0.70** against transformers.
4. **A 3.33 release is not imminent.** Release cadence from `list_releases`: 3.31.3 (2026-04-15) → 3.31.4 (2026-06-30) → 3.32.3 (2026-09-30) — roughly quarterly. Pin a **commit**, not a tag: `main` at `648693c6fcb9ec84405112b6d2fec384eae582b8` (2026-10-12), or our own fork at that SHA.
5. **Every one of the six integration surfaces is downstream of one thing we do not have: the model-agnostic spec layer.** There is no embedding code in the app at all today (no `EmbeddingCoordinator`, no `EmbeddingSpec`, no `emb_*` schema, no `semantic_search`). Search confirms zero hits for any of those identifiers under `src/ios`. So the spec layer (`EmbeddingSpec` + `EmbeddingSpecReader` + `LocalModelKind.embedding`) is not "the first surface" — it is the *only* thing that can be built first, and the CLI, tool, MCP server, intents and skills are all thin adapters over it.

---

## Part 1 — The state of MLX Swift (as of 2026-10-12)

### 1.1 Baseline and release status

| Item | Value | Source |
|---|---|---|
| Newest release | **3.32.3**, published 2026-09-30T20:38:34Z | `get_latest_release` |
| Tag commit for 3.32.3 | `3b339ad` "adjustments for running tests on NAX/TF32 hardware (#649)" | `git log -1 3.32.3` |
| `main` tip | `648693c6fcb9ec84405112b6d2fec384eae582b8`, 2026-10-12, "Complete VLM processor TODOs (#301)" | clone |
| Commits on `main` since the 3.32.3 tag | **34** | `git log 3.32.3..HEAD \| wc -l` |
| Release cadence | 3.31.3 → 3.31.4 → 3.32.3 at ~2.5-month intervals | `list_releases` |
| **3.33 imminent?** | **No.** No release branch, no 3.33 tag, no prerelease. The 3.32.x line is 12 days old. Expect the next cut around late December 2026 – January 2027 on the observed cadence. **Do not wait for it.** | tags/branches/releases |

Branches present on the remote: `codable-macro`, `fix/qwen25vl-mrope-and-rope-deltas`, `loratrain-fix`, `materialized-array`, `readme-2`, `readme-3` — none is an embedder workstream. Embedder work is arriving through PRs (#654, #685 merged; #684 open), not through a branch.

### 1.2 Everything merged since 3.32.3 (34 commits, dated)

Grouped by the date `git log --date=short` reports. All are merge commits to `main`.

**2026-10-12 (5)**
| Commit | PR | One-line |
|---|---|---|
| `9645800` | #580 | **Load model components on demand, starting with MuseGlimmer's vision encoder** — component-aware loading; adds `excludedComponents` to the weight load. Apple PR text: two decode-path optimizations for Muse-Glimmer-30B, bit-identical to reference. 23 files, +1,562/−87. |
| `0de8927` | #412 | Generation: honor `suppress_tokens` and mask multimodal placeholder tokens |
| `f3da868` | #644 | Report the reused cache prefix before prefill (prompt-cache observability) |
| `67638ff` | #690 | fix tests on main after PR merges |
| `648693c` | #301 | Complete VLM processor TODOs |

**2026-10-09 (3)**
| Commit | PR | One-line |
|---|---|---|
| `7eb77ef` | #662 | Add compiled decode for Qwen3.5 VLM models |
| `34a3fd2` | #675 | Reuse Gemma4 softcap fusion for text inference |
| `91a9565` | #685 | **MLXEmbedders: build the README example mask from text lengths** — an embedder-adjacent doc/test fix (2 files) |

**2026-10-08 (3)**
| Commit | PR | One-line |
|---|---|---|
| `a86ee6a` | #680 | scripted `Tokenizer` → new `MLXScriptedLM` library target in `Package.swift` |
| `3615fe4` | #614 | Reduce unused vocabulary projections during Qwen prefill |
| `c408452` | #633 | Fix the eps in the gated delta net q/k L2 norm |

**2026-10-07 (9 — the dense day, and the one that matters to us)**
| Commit | PR | One-line |
|---|---|---|
| `38d1493` | **#654** | **MLXEmbedders: use bidirectional attention in EmbeddingGemma** (fixes #638). 4 files, +599/−10. Adds `Libraries/MLXEmbedders/AttentionMask.swift`. |
| `c6ca658` | #672 | Split hidden states from logit projection for causal LMs |
| `8531a0f` | #627 | Conform Qwen3VL to `PreparedInputSplitting` |
| `7a9b7e6` | #641 | Let a `ChatSession` fork its cache into a new conversation |
| `0ebbdbd` | #623 | Parse GLM-4-0414 markerless tool calls (#491) |
| `e9c8500` | #663 | Fix Qwen reasoning history reconstruction |
| `22157fc` | #671 | Fix GLM4MoELite quantized KV cache attention |
| `4ea4225` | #670 | Tokenizer: flush held text when streaming generation ends |
| `a1f575d` | #625 | perf(tools): scan only the chunk for a collecting call's end tag |

**2026-10-06 (2)**
| Commit | PR | One-line |
|---|---|---|
| `ecd8e88` | #640 | Add generation observability (`Documentation.docc/generation-observability.md`) |
| `0754e10` | #626 | Fix Gemma tool calls losing nested object/array arguments to raw strings |

**2026-10-05 (3)**
| Commit | PR | One-line |
|---|---|---|
| `6d84ef6` | **#679** | **Introduce component-aware checkpoint loading** — 24 files, +1,594/−193; the machinery behind #580 (`ModelComponent.swift`, `CheckpointComponent.swift`, `ModelCheckpoint.swift`, `CheckpointNameMapping.swift`) |
| `282c2f5` | #639 | Report KV cache memory in `KVCacheStatus` |
| `c07010e` | #669 | Make reranker cancellation test deterministic |

**2026-10-03 (2)**
| Commit | PR | One-line |
|---|---|---|
| `5e46681` | #666 | Fix Jina reranker cosine scoring precision (#651) |
| `55db721` | #621 | Reduce Qwen3 reranking memory by projecting final tokens only |

**2026-10-02 (5)**
| Commit | PR | One-line |
|---|---|---|
| `ce3950e` | #642 | Drop MTP weights from converted Qwen 3.5 VLM checkpoints |
| `6e0a0b2` | #667 | Synchronize Metal before checking cached buffer memory |
| `1830ae4` | #631 | Declare the fused GDN projection as compile state so it frees with the model |
| `7e4024e` | #635 | NemotronH: MoE keys are optional, so dense checkpoints load |
| `9afc3b5` | #668 | Recommend `upToNextMinor` in installation instructions |

**2026-10-01 (1)** — `9112fae` #650: Synchronize cross-SIMD WHT reads before shared-memory writes.
**2026-09-30 (1)** — `ac6f565` #489: update documentation and skills (the `skills/mlx-swift-lm/` tree, including `references/embeddings.md`).

Scale of the delta: **178 files changed, +13,853 / −1,120** (`git diff --stat 3.32.3..HEAD`).

### 1.3 The PRs we care about, in detail

| PR | Title | State | Dates | Size | What it does for us |
|---|---|---|---|---|---|
| **#684** | Add EmbeddingGemma 2 full support (author `aleroot`) | **open, not draft, `mergeable_state: blocked`** | created 2026-10-07, updated **2026-10-12T19:41Z** | 11 files, **+3,955 / −610** | The only MLX Swift implementation of EmbeddingGemma 2 in existence. Now rebased onto #580's component machinery. |
| **#654** | MLXEmbedders: use bidirectional attention in EmbeddingGemma (author `MBark286`) | **merged 2026-10-07T16:18:25Z** | — | 4 files, +599/−10 | Correct masks for any `use_bidirectional_attention: true` Gemma-3-family embedder. **Required.** |
| **#580** | Load model components on demand, starting with MuseGlimmer's vision encoder (author `aleroot`) | **merged 2026-10-12T16:09:55Z** | — | 23 files, +1,562/−87 | The mechanism that lets a text-only user skip vision/audio towers — which is the difference between 1.49 GB and ~176 MB for EG2. |
| #679 | Introduce component-aware checkpoint loading | merged 2026-10-05T20:58:52Z | — | 24 files, +1,594/−193 | The groundwork (#580 is the consumer). |
| #685 | MLXEmbedders: README example mask from text lengths | merged 2026-10-09T15:33:15Z | — | 2 files | Embedder docs/tests only. |

**#684's current file list** (fetched with `pull_request_read … method=get_files` — note this is *newer* than the file list recorded in `EMBEDDING-GEMMA-2.md`, which predates the rebase):

| File | +/- | Note |
|---|---|---|
| `Libraries/MLXLMCommon/Models/Gemma4Encoders.swift` | +1,099 | Gemma-4 vision + audio towers |
| `Libraries/MLXLMCommon/Models/EmbeddingGemma2.swift` | +848 | shared core + `embed(inputIds:attentionMask:)`, `imageFeatures`, `audioFeatures` |
| `Libraries/MLXVLM/EmbeddingGemma2.swift` | +778 | `EmbeddingGemma2Embedding` actor: `.text/.image/.audio`, task enum, `dimensions:` MRL truncation, `loadVision/loadAudio` flags |
| `Tests/MLXLMTests/EmbeddingGemma2Tests.swift` | +1,019 | parity tests |
| `IntegrationTesting/IntegrationTestingTests/EmbeddingGemma2ComponentIntegrationTests.swift` | **+89 (new)** | **tests component-aware (text-only) loading — the #580 rebase is real** |
| `Libraries/MLXEmbedders/README.md` | +71 | Swift usage |
| `Libraries/MLXEmbedders/Models/EmbeddingGemma2.swift` | +24 | `EmbeddingModel` conformance: `poolingStrategy = .none`, `maxPositionEmbeddings = 8192`, returns `pooledOutput` |
| `Libraries/MLXEmbedders/ModelFactory.swift` | +7 | registers `embedding_gemma2` and `embedding_gemma2_text`; adds `EmbedderRegistry.embeddinggemma2` |
| `Libraries/MLXLMCommon/ModelComponent.swift` | **+3** | the tiny hook into #580's component loading |
| `Libraries/MLXEmbedders/Pooling.swift` | +2 | `if model is EmbeddingGemma2 { return Pooling(strategy: .none) }` |
| `Libraries/MLXVLM/Models/Gemma4.swift` | +15/−610 | refactor onto the shared encoders |

The PR body claims: *"Checked against the Transformers default SDPA path, the one Sentence Transformers uses: cosine 0.9999 for audio, video and interleaved inputs, and 0.99995 at 2,880 and 7,490 tokens."* `mergeable_state: blocked` on GitHub means **review/required-check gating, not a conflict** — 11 files and 5/5 checks green as of the last read.

### 1.4 Registries: what has actually been added

| Registry | At 3.32.3 | At `main` | Change |
|---|---|---|---|
| `LLMModelFactory` model types | 62 | 62 | **none** — set-diff is empty (checked by extracting every `"key": create…` pair from both revisions) |
| `EmbedderTypeRegistry.shared` | 10 keys → 5 types: `bert`, `roberta`, `xlm-roberta`, `distilbert`, `nomic_bert`, `qwen3`, `lfm2`, `gemma3`, `gemma3_text`, `gemma3n` | identical | **none** |
| `EmbedderRegistry` pre-made `ModelConfiguration`s | ~22 | ~22 | none |
| New public library target | — | `MLXScriptedLM` | added (`Package.swift`, commit `a86ee6a`) |
| Apple's own docs | `skills/mlx-swift-lm/references/embeddings.md` | rewritten in #489 (+/−128 lines) | **note the doc's "Supported Architectures" table lists only `bert`, `nomic_bert`, `qwen3` — it is stale relative to the registry, which also has `roberta`, `xlm-roberta`, `distilbert`, `lfm2`, `gemma3`, `gemma3_text`, `gemma3n`.** Do not use that table as ground truth; read `ModelFactory.swift`. |

Two consequences worth stating plainly:

* **Apple has shipped no new *architecture* for us in this window.** What landed is mechanism: component-aware checkpoints (#679/#580), a better embedder mask (#654), embedded-model docs (#685). That is actually the right shape — it means our provider work is about *specs and integration*, not about porting.
* **Runtime registration is the extension point, and it already exists.** `EmbedderTypeRegistry.shared` is a public static `ModelTypeRegistry<EmbeddingModel>` actor, so the app can `await EmbedderTypeRegistry.shared.registerModelType("name") { data in … }`. But the closure returns a compiled Swift type, so this removes the *enum*, not the *compiler*. Coverage of architectures is the lever; everything else (pooling, prefixes, dims, dtype, truncation, normalisation, max length) is data. That split is exactly the three-layer design in `EMBEDDING-INTEGRATION.md` §5.2, and this report does not re-argue it.

### 1.5 MTP / speculative decoding

MTP (multi-token prediction) is an area of active work but is **not our path** — it is Qwen3.5/Gemma-4-specific and it is about chat decode speed, not embeddings. Since 3.32.3:

* `Libraries/MLXLMCommon/MTPSpeculativeTokenIterator.swift` (+35), `MTPDrafterModelFactory.swift` (+3), `Libraries/MLXLLM/Models/Qwen35MTP.swift` (+53), `MLXVLM/Models/Qwen35MTP.swift` (+53).
* **`ce3950e` #642 — "Drop MTP weights from converted Qwen 3.5 VLM checkpoints"**: conversions were carrying MTP tensors that the runtime does not need. Relevant to us only as a reminder to keep converted checkpoint repos lean.
* Tests added/updated: `MTPSpeculativeTokenIteratorTests`, `SpeculativeDecodingTests`, `SpeculativeRoundRewindTests` (+312 — rewind on a rejected draft), `MTPGenerateAPITests`, `MTPAcceptanceRateTests`, `MTPQuantizationOnsetTests`, `MTPRung4TokenParityTests`, `MTPIteratorEndToEndDiagnosticTests`.
* **Nothing about MTP affects the embedder path.** An embedding engine must not grow an MTP dependency; if we ever add a *speculative* embedder, the analogue of "rewind" is exact-vector parity, which is a test, not a mechanism.

### 1.6 KV-cache changes

| Change | Commit | Why it matters to a second model kind |
|---|---|---|
| KV cache memory reported in `KVCacheStatus` (#639) | `282c2f5` | Directly relevant: the **residency arithmetic** for an embedder must *subtract* a KV term the chat model has and an encoder does not. Having the runtime report KV bytes makes the admission check honest instead of estimated. |
| `ChatSession` can fork its cache into a new conversation (#641) | `7a9b7e6` | Chat-only; no embedder analogue. |
| GLM4MoELite quantized-KV attention fix (#671) | `22157fc` | Quantized-KV correctness; only matters to us because both kinds of model share one Metal queue and one `Memory.cacheLimit`. |
| `KVCache.swift` +25, `KVCacheConfiguration.swift` +7, `CacheConfiguration.swift` +5, `TurboQuantKVCache.swift` +48, `VarianceNormalizedKVCache.swift` +7 | — | The cache surface keeps growing; **none of it is on the encoder path.** An encoder forward pass with no cache is unaffected by any of this, which is the point: "bidirectional encoder embedder" is genuinely cache-free. |

### 1.7 Wired memory

**Nothing new landed since 3.32.3.** `Libraries/MLXLMCommon/WiredMemoryPolicies.swift` last changed in `1b063d0` "Added wired memory control (#72)" dated **2026-02-12**, and `git merge-base --is-ancestor 1b063d0 3.32.3` confirms it is **already in 3.32.3**. The only diff in the window is 8 doc lines in `skills/mlx-swift-lm/references/wired-memory.md`.

What it gives us (verbatim from Apple's reference, which is the authoritative summary):

* Policies: `WiredSumPolicy`, `WiredMaxPolicy`, `WiredFixedPolicy`, `WiredBudgetPolicy`.
* Measurement: `WiredMemoryUtils`, `WiredMemoryMeasurement`.
* Integration point: the `wiredMemoryTicket:` parameter on both text-level and token-level generation APIs; `WiredMemoryTicket.withWiredLimit`.
* Ticket kinds: **`.active`** (contributes while inference runs) vs **`.reservation`** (tracks long-lived budgets such as model weights without holding the limit up when idle).

**Design consequence, and it is a real one:** an always-resident Tier-0 embedder's weights belong in a **`.reservation`** ticket, not an `.active` one; an in-flight embedding batch takes an **`.active`** ticket sized `weights + activation_scratch`. That is the same arithmetic split as `LocalModelHost.runCost` (weights + KV + working), minus KV. Do not invent a second memory-accounting scheme.

### 1.8 What a project on 3.32.3 is missing — concrete list

1. **Correct EmbeddingGemma-family embeddings.** #654 is not in 3.32.3. Any `gemma3`/`gemma3_text`/`gemma3n` embedder loaded from our pin builds causal masks (the PR measured cosine 0.45–0.70 vs transformers, float32, `google/embeddinggemma-300m`). Also absent: `Libraries/MLXEmbedders/AttentionMask.swift` and `createBidirectionalAttentionMask(length:halfWindow:paddingMask:)` entirely.
2. **Text-only loading of multimodal encoders.** #679 + #580 + `ModelComponent.swift` + `CheckpointComponent.swift` + the `excludedComponents:` argument to `loadWeights(modelDirectory:model:perLayerQuantization:weightFileSelection:excludedComponents:)` are all post-cut. On 3.32.3 there is no supported way to load "the text tower of a 1.49 GB multimodal encoder" without downloading and mapping all of it.
3. **EmbeddingGemma 2 in any form.** Not at 3.32.3, not at `main`; only in PR #684's branch.
4. **The bidirectional-mask test coverage** (`BidirectionalAttentionMaskTests.swift` +233, `EmbeddingGemmaMaskTests.swift` +257) — i.e. the proof that padded batches equal single-text runs. Without it, batched embedding is a silent-quality-risk.
5. **Three embedder-facing fixes that happen to be post-cut:** mask-from-text-lengths (#685), Jina reranker cosine precision (#666), Qwen3 reranker memory by projecting final tokens only (#621). If we plan to use `MLXRerankers`, #666 is a correctness fix, not a nicety.
6. **Smaller but free wins:** `suppress_tokens` support (#412) affects local chat quality; the reused-prefix report (#644) and generation observability (#640) affect our ability to *measure* the embedder/chat coexistence story; `scripted Tokenizer` (#680) gives us deterministic test infrastructure for prompt/prefix assembly — useful for asserting `task: search result | query: …` assembly without a real model.
7. **Not missing, do not worry about it:** wired memory, KV-cache quantization, tool-calling, the sampler path, MTP. All present or irrelevant to us.

**Recommendation:** vendor a fork at `main` = `648693c6fcb9ec84405112b6d2fec384eae582b8`, cherry-pick nothing, and take PR #684 as a *branch* dependency (`aleroot/alessio/public-gemma4-vision-encoder`) behind a compile flag if EG2 is needed before the merge lands. Pinning the released tag and patching locally is the worst option: it makes our diff unmaintainable exactly where Apple is most active.

---

## Part 2 — EmbeddingGemma 2 and Harrier: exactly what the *provider* must change, and who has already supplied it

The question this part answers is not "does it work" but **"who owns each requirement"** — Google (model card / repo files / transformers), Apple (MLX Swift source and `skills/`), or nobody. The last category is the work we cannot delegate, and it is where all the risk lives.

### 2.1 EmbeddingGemma 2 — verified facts first (fetched live, 2026-10-12)

`google/embeddinggemma-2` is **no longer gated** — I read `config.json`, the ST config files and the card directly.

| Fact | Value | Where it came from |
|---|---|---|
| Repo rev / last modified | `914f7f89142e33e77833254d9c9b90c3cef7303b`, 2026-10-06T15:29Z | HF model API |
| `model_type` (top level) | **`embedding_gemma2`**, `architectures: ["EmbeddingGemma2Model"]` | `config.json` |
| `model_type` (text sub-config) | **`embedding_gemma2_text`** | `config.json` → `text_config` |
| Text tower | hidden **512**, 24 layers, 4 heads, `head_dim` 256, sliding window **512**, `layer_types` = 20 × `sliding_attention` + 4 × `full_attention` (layers 5, 11, 17, 23), `per_layer_config` overrides `{head_dim: 512, num_key_value_heads: 1}` on those same four layers | `config.json` |
| `max_position_embeddings` | **262144** | `config.json` |
| **Documented usable context** | **8,192 tokens** ("Context Window 8,192 tokens"; "a single shared 8,192-token context") | model card |
| Pooling | **Mean pooling**, then projection **512→768**, native output **768** | card table ("Pooling: Mean Pooling", "Projection Layer: 512→768") |
| MRL truncation dims | **768 / 512 / 256 / 128**; "Re-normalize after truncating" | card, §"3. Matryoshka Dimension Truncation" |
| Precision | **"Run inference in `bfloat16` or `float32`. Do not use `float16`."** In fp16 the model "returns NaN or silently degraded embeddings rather than raising an error" | card, §"4. Numerical Precision" |
| Task prefixes | 20 named prompts, machine-readable | `config_sentence_transformers.json` (see §2.2) |
| Multimodal budget | 280 tokens/image, 140 tokens/frame, 25 tokens/second of audio; ~29 images / ~58 frames / ~327 s default maxima; vision "soft token" budget tunable 70–1120 | card, §"Context Limits" / "Vision Token Budget" |
| Towers | 740M total = **270M text + 170M vision + 300M audio**; `gemma4_vision` (hidden 768, 16 layers, patch 16, 280 soft tokens/image), `gemma4_audio` (hidden 1024, 12 layers, `output_proj_dims` 1536) | card + `config.json` |
| Single weight file | `model.safetensors` = **1,488,915,288 bytes (1.489 GB)** — all towers in one file | HF API `?blobs=true` |
| Repo also ships | `chat_template.jinja` (placeholder-filling template for `<\|image\|>`/`<\|video\|>`/`<\|audio\|>`), `preprocessor_config.json`, `processor_config.json` (`Gemma4ImageProcessor`, `Gemma4AudioFeatureExtractor`, 16 kHz), `tokenizer.json` (32.2 MB) | HF API + files |

**Two file-level discoveries that change the spec layer's design** (neither is mentioned in the prior reports, and both are load-bearing):

1. **`1_Pooling/config.json` uses the new sentence-transformers 6.x schema, not the legacy one:**
   ```json
   { "embedding_dimension": 768, "pooling_mode": "mean", "include_prompt": true }
   ```
   The legacy schema (what `bge-*`, `MiniLM`, `nomic` ship) is `word_embedding_dimension` + `pooling_mode_*` booleans. `MLXEmbedders/Pooling.swift` decodes only the legacy names, and `dimension` is decoded with a **required** `try container.decode(Int.self, forKey: .dimension)` — so on this file the decode **throws**, `try?` swallows it, and `loadPooling` falls through to `model.poolingStrategy`. With PR #684 that fallback is `.none` (correct, because the model pools internally). **Without #684 the fallback is "no pooling at all" on a model whose `EmbeddingModel` conformance does not exist anyway.** The general lesson stands: our `EmbeddingSpecReader` must understand **both** schemas, and must treat "pooling file present but unreadable" as an explicit, logged condition rather than a silent fallback.
2. **`sentence_bert_config.json` no longer carries `max_seq_length`.** EG2's is the new `transformer_task` + `modality_config` shape (per-modality `method: forward`, `output_name: last_hidden_state`, `module_output_name: token_embeddings`). So the field the previous report designated as *the* chunking authority is **absent for this model** — and the documented 8,192 is nowhere in the files. The 8,192 limit must be an **app-side spec field**, sourced from the card, with `provenance["maxTokens"] = "model card"`.
   Likewise `modules.json` uses ST 6.x module paths (`sentence_transformers.sentence_transformer.modules.pooling.Pooling`), so a reader that string-matches `sentence_transformers.models.Pooling` will fail on this repo. **`2_Normalize` is present ⇒ `normalize = true`.** The reliable rule is: *presence of a Normalize module in `modules.json`, or an `embedding_dimension`/`word_embedding_dimension` field, or the card — never a single fixed path.*

### 2.2 EmbeddingGemma 2 — requirement-by-requirement, with owner

| # | Requirement | Documented by | Engine work or app work | Supplied by |
|---|---|---|---|---|
| 1 | `model_type` registration: `embedding_gemma2` **and** `embedding_gemma2_text` → one Swift type | **Google** (both keys in `config.json`; the card never mentions `model_type`) | **Engine** (a registry key + a Swift model class). App side needs the *allow-list* update only. | **PR #684** (`ModelFactory.swift` +7, `Embedders/Models/EmbeddingGemma2.swift` +24). Apple has **not** merged it. |
| 2 | Pooling strategy = **`.none`** (the model pools internally) | **Google**, indirectly: card says "Mean Pooling" + "Projection Layer 512→768"; repo file says `pooling_mode: "mean"`. The *implication* "therefore the caller must not pool" is documented by nobody. | **Engine** (one line) + **app** (must call `context.pooling(...)` with `.none`, i.e. pass through `pooledOutput`) | **PR #684** (`Pooling.swift` +2). On our pin/main today the correct behaviour is unreachable *and* the pooling decode fails on the new schema. |
| 3 | **√512 input pre-scale** | **Nobody.** Google's card is silent; transformers implements it as `Gemma3TextScaledWordEmbedding` (`hidden_size ** 0.5`); MLX Swift implements the same rule generically at `Libraries/MLXEmbedders/Models/Gemma3.swift:382` — `let scale = MLXArray(sqrt(Float(config.hiddenSize)), dtype: .bfloat16)`. So for EG2 it is `sqrt(512) = 22.63` automatically, **and for Harrier it will be `sqrt(640) = 25.30`** — also correct. | **Engine** — and it is already generic, not per-model. | Already in the Gemma backbone (both at 3.32.3 and `main`). **Nothing to write.** Note the hardcoded `.bfloat16` dtype at that line: fine for bf16 weights, worth an eye if we ever load fp32. |
| 3b | **Never fp16; if quantising, guard the RMSNorm magnitude** | **Google** (card §4, "Do not use float16", explicitly) | **Engine/loading policy.** Separately, FluidInference's Core ML conversion reports plain fp16 RMSNorm yields cosine 0.95 vs 0.9996 when the conversion first divides by row max-abs — the same overflow risk exists in any fp16 MLX port [**unverified** for MLX specifically] | Google supplies the prohibition; nobody supplies an MLX guard. **Load bf16/fp32; only ever quantise (not fp16-cast).** |
| 4 | **Mandatory task prefixes**: `task: search result \| query: {query}` for queries, `title: {title} \| text: {content}` (or `title: none \| text: …`) for documents, plus 17 other task strings | **Google**, comprehensively — card §"1. Task Instruction Prefixes" **and** machine-readable in `config_sentence_transformers.json` (20 prompt names: `SearchQuery`, `Retrieval`, `Document`, `Classification`, `Clustering`, `SentenceSimilarity`, `CodeRetrieval`, `QuestionAnswering`, `FactChecking`, `BitextMining`, `Reranking`, `STS`, `Summarization`, …). Note the wording: *"Using the right prefix improves quality; omitting it still works but reduces precision"* — so the policy is **optional-but-recommended**, not mandatory. Prefixes apply to text only; media are passed unprefixed. | **App work** (spec layer writes `queryPrefix`/`documentPrefix` + a task→prompt map; the model takes a `task:` enum). No engine change. | **Google supplies the data** (in the repo, not just the card). **We write the reader** — this is the happy path: the previous report listed these as "[unverified exact strings]"; they are now verified *and* machine-readable. |
| 5 | mean-pool → `Linear(512→768)` → L2 | **Google** (card: Mean Pooling; Projection 512→768) | **Engine** (inside the `EmbeddingModel` conformance; the projection matrix is inferred from the checkpoint's `dense.0.weight` shape — the same trick `EmbeddingGemma.sanitize` uses for EG1) | **PR #684.** App must not re-pool and need not re-normalise (double L2 is idempotent). |
| 6 | Matryoshka truncation to **512 / 256 / 128** with **re-normalisation** | **Google**, emphatically: *"Re-normalize after truncating: slicing a unit-length vector does not preserve unit length… Skipping this step degrades ranking quality silently — it produces plausible-looking scores rather than an error."* Also *"Queries and documents must share a dimension."* | **Engine**: "truncate then L2" must be the *only* order. MLX's `Pooling` does it in exactly that order (`if let dimension { pooled = pooled[0..., 0..<dimension] }` … `if normalize { pooled = pooled.l2Normalized() }`). `EmbeddingGemma2Embedding.embed(…, dimensions:)` is the other route. **App**: store the *truncated* `dim` on every vector row and refuse cross-dimension comparisons. | Engine route exists (`Pooling.dimension`, PR #684's `dimensions:`). **The app-side guard is ours**, and the previous report already specifies `assertCompatible(_:with:)`. |
| 7 | **Text-only loading** (skip the 170M vision + 300M audio towers) | Google ships **one 1.489 GB safetensors for everything** — i.e. Google documents the opposite of what we want; there is no text-only repo from Google. | **Engine**: component-aware loading. **App**: pick the components to exclude, or ship our own text-only conversion. | **#679 + #580 (merged) supply the mechanism; PR #684 supplies the wiring** (`ModelComponent.swift` +3, plus a dedicated `EmbeddingGemma2ComponentIntegrationTests.swift`). Concretely: 1.49 GB full vs the measured **~176 MB** 4-bit text-only build — a **8.5×** difference, so this is not an optimisation, it is the difference between shipping and not shipping. |
| 8 | **8,192-token context** | **Google** (card). Nowhere in the files: `config.json` says 262144, `sentence_bert_config.json` has no length, `tokenizer.json`'s model_max_length is not authoritative. | **App work** — `spec.maxTokens = 8192`, `provenance = "model card"`, and the chunker honours it (chunk *before* the encoder, never rely on internal truncation). | **Nobody supplies it in data. We write it.** This is the second "nobody" item. |
| 9 | Optional vision/audio towers and their footprints | **Google** (card: 170M/300M; 280 tokens per image, 140/frame, 25 tokens/s audio; GEMMs and soft-token budget) | **Engine**: `Gemma4Encoders.swift` +1099, `MLXVLM/EmbeddingGemma2.swift` +778, an `EmbeddingGemma2Embedding` actor with `loadVision/loadAudio` flags, plus `Gemma4ImageProcessor`/`Gemma4AudioFeatureExtractor` equivalents on our side (media decoding is app work: `AVAssetReader`, `AVAudioFile`, resampling to 16 kHz). | **PR #684 supplies the towers.** The *decision* to ship them is ours — and per the coexistence arithmetic, a 4B chat model + full-multimodal 4-bit EG2 is ~3.9 GB combined vs ~2.8 GB text-only. **Ship text first.** |
| 10 | Interleaved input & placeholder tokens | **Google** (card §"Multimodal Input"; `<\|image\|>`, `<\|video\|>`, `<\|audio\|>`), plus `chat_template.jinja` in the repo implements the filling rule | **Engine + app**: placeholder token ids are in `config.json` (`image_token_id` 258880, `video_token_id` 258884, `audio_token_id` 258881, `boi_token_id` 255999, `eoi_token_id` 258882, `boa_token_id` 256000). Getting this wrong is the multimodal equivalent of a prefix bug. | Google supplies the tokens and the template; PR #684 implements the input split. **App work** for building the placeholder text on our side. |

### 2.3 Harrier — verified facts, and a correction

Both repositories were fetched live. The card's own comparison table, and the `config.json` files:

| | `microsoft/harrier-oss-v1-270m` | `microsoft/harrier-oss-v1-0.6b` |
|---|---|---|
| **`model_type` (verified)** | **`gemma3_text`** | **`qwen3`** |
| `architectures` | `["Gemma3TextModel"]` | `["Qwen3Model"]` |
| Repo rev | `31de22b673913c7d658c0f03f792d77c2dcf8ebd` (2026-03-30) | `f9b9dc8d367d443f2479d27aa5d8d2850c0774ee` (2026-03-30) |
| HF tags | `sentence-transformers`, `safetensors`, **`gemma3_text`**, `feature-extraction`, `text-embeddings-inference`, multilingual | `sentence-transformers`, `safetensors`, **`qwen3`**, `feature-extraction`, `text-embeddings-inference`, multilingual, `deploy:azure` |
| **Embedding dimension** | **640** | **1024** (the task text says 640 for the family — **that is only true of the 270m**) |
| Hidden size / layers / heads | 640 / 18 / 4 q, **1 kv**, `head_dim` **256**, `query_pre_attn_scalar` 256 | 1024 / 28 / 16 q, 8 kv, `head_dim` 128 |
| **Context** | `max_position_embeddings` **32768** — and the card's "Max Tokens" column also says **32,768**, so config and documentation agree | same, **32,768** |
| Sliding window | `sliding_window: 512`, `sliding_window_pattern: 1`, all 18 `layer_types` = `full_attention` | `sliding_window: null`, `use_sliding_window: false`, `max_window_layers: 28`, all `full_attention` |
| `use_bidirectional_attention` | **`false`** | (n/a) |
| `vocab_size` | 262144 | 151936 |
| Tied embeddings | not declared | `tie_word_embeddings: true` |
| MTEB v2 (card) | 66.5 | 69.0 |
| Pooling (verified from `1_Pooling/config.json`) | `word_embedding_dimension: 640`, **`pooling_mode_lasttoken: true`**, all others false, `include_prompt: true` | `word_embedding_dimension: 1024`, **`pooling_mode_lasttoken: true`**, `include_prompt: true` |
| Normalisation | `modules.json` contains `2_Normalize` ⇒ **normalize = true** | same |
| Prompts (verified from `config_sentence_transformers.json`) | `web_search_query`: `Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: `; `sts_query`: `Instruct: Retrieve semantically similar text\nQuery: `; `bitext_query`: `Instruct: Retrieve parallel sentences\nQuery: `; `default_prompt_name: null` | identical file, identical prompts |
| `similarity_fn_name` | `cosine` | `cosine` |
| Tokenizer flags | `add_bos_token: true`, **`add_eos_token: true`**, eos `<eos>`, pad `<pad>` | `add_bos_token: false`, **no `add_eos_token` key**, eos `<|im_end|>` (= `eos_token_id` 151645), pad `<|endoftext|>` |

**Correction to the premise:** the card does **not** say queries *must* carry an instruction. What it shows is `model.encode(queries, prompt_name="web_search_query")` for queries and `model.encode(documents)` bare for documents, and it says *"You can also use a custom instruction directly via e.g. `model.encode(queries, prompt="Instruct: …")`"*. Read strictly: the instruction is a **query-side, quality-improving convention**, documented in the repo as data (`config_sentence_transformers.json`), with policy `optional-but-recommended` for queries and `forbidden`/`none` for documents. Treating it as mandatory would be a misreading of the card — but treating documents as requiring an instruction would be a worse error, because the card's example scores bare documents.

**The four things that decide whether Harrier works, none of which need new compiled code:**

1. **Both `model_type`s are already in `EmbedderTypeRegistry`.** `gemma3_text` → `create(Gemma3Configuration.self) { EmbeddingGemma($0) }`; `qwen3` → `create(Qwen3Configuration.self) { Qwen3Model($0) }`. So **at 3.32.3, unmodified, `EmbedderModelFactory.shared.loadContainer(from:using:configuration: ModelConfiguration(id: "microsoft/harrier-oss-v1-270m"))` is expected to load.** Neither Harrier variant needs a registry key, a new Swift type, or a PR. It is **config-driven registration** in the strict sense: our app already accepts the repo (`LocalModelCatalog.isLoadable` = config.json + `.safetensors`; standard safetensors is fine, `skipExtensions` only excludes GGUF/PyTorch/ONNX).
2. **Pooling is `.last` and the file supplies it.** `PoolingConfiguration` has `case poolingModeLastToken = "pooling_mode_lasttoken"` and the resolution order is CLS > Mean > Max > **Last** > First, so with only `lasttoken: true` set, `loadPooling` returns `Pooling(strategy: .last)` and `dimension = 640` (a no-op truncation here). **No code.**
3. **`use_bidirectional_attention: false` means the causal mask is CORRECT.** This is the inverse of the EmbeddingGemma trap: Harrier is a *decoder-only* model with last-token pooling (card: *"The models use decoder-only architectures with last-token pooling and L2 normalization"*), so #654 changes nothing for it. The corollary is more important than the fact: **our spec layer must not assume "embedder ⇒ bidirectional"**, and #654 must be understood as honouring a per-checkpoint flag, not as a global embedder fix.
4. **The tokenizer's EOS convention is unverified and it is load-bearing.** Harrier-270m declares `add_eos_token: true`, so in transformers/ST the last token is `<eos>` — and `.last` pooling takes the last non-pad token. swift-transformers may or may not replicate `add_eos_token` (that flag is applied by `PreTrainedTokenizer`, whereas a fast tokenizer's post-processing comes from `tokenizer.json`'s `post_processor`). For the 0.6b there is no `add_eos_token` key at all, and Qwen3-Embedding-family recipes conventionally append `<|endoftext|>` while Harrier's eos is `<|im_end|>`. **This is the one Harrier item that can silently cost quality with no error.** It needs a measured answer, not a reading: encode one sentence in HF/sentence-transformers (or `text-embeddings-inference`), encode the same sentence through `MLXEmbedders` with and without an explicit EOS, and pick the variant with the higher cosine. Record the winner in the spec as `appendEosToken: Bool` with `provenance = "measured"`. If the answer is "the tokenizer already appends it", the spec field is `false` and we are done. Note this is *also* true of EG2 (whose document prefix ends with a space and whose tokenizer is Gemma-4's) — the same test will answer both.

**Matryoshka for Harrier: [unverified].** Neither card mentions MRL, the `1_Pooling` files carry no MRL dims, and no truncation-quality table exists. **Assume no MRL unless measured**: 640 and 1024 are the dims we should store, and a "truncate to 256" experiment must be treated as a *quality experiment*, not a supported feature. Contrast with EG2, where Google publishes the whole per-dimension table.

**What needs new compiled code vs config-driven registration — Harrier:** **nothing needs new compiled code.** Everything is config-driven (architecture key, pooling, dimension, normalisation flag) or app-side spec data (prefixes, EOS policy, chunk length, task prompts). The only way Harrier would need compiled code is if measurement shows `.last` must *skip* a trailing EOS rather than take the last non-pad token — a change in `Pooling.swift`, i.e. engine, and it would affect every `.last` model, so it would need a spec flag (`lastTokenPolicy`) rather than a special case.

### 2.4 The consolidated table

| Model | What the engine needs | Who supplies it | Do we write code? |
|---|---|---|---|
| **EmbeddingGemma 2** (`google/embeddinggemma-2`) | `embedding_gemma2` + `embedding_gemma2_text` keys; a `Gemma4`-based encoder; internal mean-pool → `Linear(512→768)` → L2; `poolingStrategy = .none`; `maxPositionEmbeddings = 8192`; MRL `dimensions:`; component-based text-only loading; vision/audio towers | Google: architecture facts, pooling, projection, MRL dims + the re-normalisation rule, prefixes, context limits, precision rule, tower token costs, placeholder tokens. **PR #684**: all of the Swift. Apple: nothing yet (open, blocked). | **Yes — but as vendoring/integration, not authoring.** Take #684 as a branch dep or fork; the ~3,955 lines are already written. Our own code: the spec reader (both `1_Pooling` schemas), the 8,192 value, the chunker, and the vocabulary/marker plumbing. **~2 "nobody" items, both small.** |
| **Harrier-270m** | Nothing at the architecture or pooling layer: `gemma3_text` → `EmbeddingGemma`; `.last` from `1_Pooling/config.json`; 640-d; causal mask (correct); normalise via `2_Normalize`; query instruction from `config_sentence_transformers.json` | Microsoft: `config.json`, `1_Pooling`, `modules.json`, `config_sentence_transformers.json`, card. Apple: the registry key and the loader (already in 3.32.3). | **No new compiled code.** App-side spec entries only (EOS policy, prompt map, `normalize = true` from `modules.json`, MRL marked unsupported). **One measured experiment** (EOS), not code. |
| **Harrier-0.6b** | Same as above, plus: `qwen3` → `Qwen3Model` (`poolingStrategy = .last`, reads `max_position_embeddings`, default 32768); 1024-d; `tie_word_embeddings` | same as above | **No new compiled code.** Same app-side spec work. |
| **EmbeddingGemma-1** (`mlx-community/embeddinggemma-300m-4bit`, 173 MB) | Nothing new — but **must** be on a revision ≥ #654 or embeddings are causally masked | Apple (#654); community conversion | **No.** Best pipeline-proving target today. |
| Any future `embedding_gemma*` with `use_bidirectional_attention: true` | Nothing new (the flag is honoured per checkpoint since #654) | Apple | No. |

**One Harrier footgun to write down, because it will bite:** the `EmbeddingGemma` class for `gemma3_text` computes a **mean-pooled, L2-normalised `pooledOutput` internally**. For Harrier-270m that internal pooling is *wrong* (Harrier needs last-token), while `poolingStrategy` in the container is `.last`. The two agree only because the honest path — `context.pooling(output, mask: attentionMask, normalize: true)` — reads `hiddenStates` and applies `.last` itself. **Any code path that reaches for `modelOutput.pooledOutput` on a `gemma3_text` checkpoint will silently return a mean-pooled vector.** Rule for the engine: the container's `context.pooling` is the single pooling authority; `pooledOutput` is only legal when `spec.pooling == .noneMul` (i.e. EG2). This one rule prevents a class of bug that would otherwise look like "Harrier is a bit worse than the leaderboard says".

---

## Part 3 — Model families by execution path: what each one actually demands

The point of this part is to separate what is *shared* from what is *genuinely different*, because "one engine, several model kinds" only works if the differences are enumerated and the shared parts are named once.

### 3.1 The families

| Family | Examples we care about | What the engine must provide | Shared machinery (already exists) | Genuinely different |
|---|---|---|---|---|
| **1. Causal LLM with KV cache (chat)** | Qwen3-4B, Qwen3.5, Gemma-4, LFM2 | Sampler (`topP`/`topK`/`minP` → `TopPSampler`), token loop, KV cache + optional quantized/TurboQuant/VarianceNormalized variants, prefix reuse + cache fork, tool-call parsing from the chat template, speculative/MTP drafter | `ModelContainer`, `KVCache*`, `ChatSession`, `TokenLoopHandler`, `GenerationConfigFile`, `Evaluate.swift` | **Growing cache** (per-token KV bytes — `LocalModelInfo.kvBytesPerToken` already models it), sampling, multi-turn state, MTP/speculative |
| **2. Bidirectional encoder embedder, no KV** | MiniLM, bge-*, nomic-bert, EmbeddingGemma-1/2, Harrier, Qwen3-Embedding | Attention mask shape (bidirectional band / global), pooling (`.mean/.cls/.last/.none`), matryoshka `dimension`, L2, batch padding that is *provably equivalent* to single-text runs | `EmbedderModelContainer` (+`SerialAccessContainer`), `EmbeddingModel` protocol, `ModelConfiguration`, tokenizer, weight load + `sanitize` + quantisation, `Memory.cacheLimit` | **No cache, no sampler, one forward pass**, and a correctness contract that is *batch invariance* rather than *token-by-token equivalence*. Also: pooling lives outside the model for most architectures, so it must be spec-driven (§2.3's footgun). |
| **3. VLM (vision + text)** | Qwen3-VL, Qwen3.5-VL, Gemma-4, FastVLM, SmolVLM2, MuseGlimmer | Image/video preprocessing, placeholder-token masking, per-model media budgets, `PreparedInputSplitting`, component loading to skip towers | Everything in family 1 **plus**: `VLMModelFactory`, `MediaProcessing`, `preprocessor_config` handling, the shared `MLXLMCommon` checkpoint/component layer | **Media decode + token budget** (an image costs 280–`vision_soft_tokens_per_image` tokens *inside* the same context window as text), and outputs where hidden states must be split before the logit projection (#672) |
| **4. Multimodal embedder (vision/audio towers)** | EmbeddingGemma 2 (text 270M + vision 170M + audio 300M) | Everything in 2 **and** 3, minus sampling/cache: interleaved placeholder text, tower encoders producing soft tokens in the *same* 512-d space, a shared 8,192-token budget across modalities, tower loading flags | `MLXEmbedders` container for the text path; `MLXVLM` for towers/processors; `ModelComponent` (#580) for partial loads; the same tokenizer | **Two new things:** (a) *selective component residency* (a 1.49 GB repo where we want 176 MB), and (b) *one vector from many modalities* — the pooling decision moves inside the model (`.none`), so the engine must accept "the model returns the vector" as a first-class shape |
| **5. Cross-encoder / reranker** | Jina reranker, bge-reranker, Qwen3 reranker | Sequence-classification head + a score policy, query–document pair batching, micro-batching with `Task.checkCancellation()` | `MLXRerankers` (`RerankerModel: EmbeddingModel`), `EncoderRerankerScorePolicy` (`.singleLogit`, `.classLogit`, `.binaryMargin`, `.softmaxProbability`), `EmbedderModelContainer.rerankerScores(query:documents:options:)`, `BERTRerankerInputProcessor` / `XLMRobertaRerankerInputProcessor` | **A classification head, not a pooler**; scores are not comparable across models; the pair-formatting is model-specific (a template, not a prefix); memory is dominated by *documents × length*, so batching discipline is the design |
| **6. Late interaction (ColBERT)** | LFM2.5-ColBERT-350M (`lfm2` + a `"mlx"` head) | Multi-vector output — one 128-d vector **per token** — and MaxSim scoring | `LFM2BidirectionalModel` (already in `EmbedderTypeRegistry["lfm2"]`), the tokenizer, batching | **Everything else is different**: the storage schema (N vectors per document, not one), the index arithmetic (N× storage), scoring (`MaxSim`, not cosine), and `Pooling.Strategy` has no case for it — you get `hiddenStates` and keep them. **Relevant only if we decide we want it; it is not on the critical path and it would double the index work.** |

### 3.2 The shared spine, stated once

Everything above runs through the same four seams, and any "one engine" design must not duplicate them:

1. **The container seam.** `EmbedderModelContainer` (embedders) and `ModelContainer` (LLMs/VLMs) both exist, both are `Sendable`, both serialise access, and both hand you a context you must not let escape (`perform { ctx in … }` — `MLXArray` is not `Sendable`, so vectors must be converted to `[Float]`/`Data` before returning). **An embedding engine should own one `EmbedderModelContainer` per resident embedder and nothing else.**
2. **The weight seam.** `ModelConfiguration` / `ResolvedModelConfiguration`, the downloader's revision-pinned resolve URL, `sanitize(weights:)`, `perLayerQuantization`, and now `weightFileSelection` + `excludedComponents`. Every family benefits from #679/#580: the same mechanism that lets a VLM skip an unused encoder lets an embedder skip a media tower.
3. **The memory seam.** One `MTLDevice`, one `Memory.cacheLimit` (64 MB by design in this codebase), one process-global wired-memory manager. `LocalModelHost` currently enforces a **single slot**; embeddings need a *second kind of slot* (weights + scratch, no KV) and the generative admission check must subtract the resident embedding weights. This is the one change that touches the chat path, and it is arithmetic, not architecture.
4. **The scheduling seam.** `SerialAccessContainer` serialises but does not *schedule*. Since MLX shares one Metal queue per process, an embedder batch genuinely stalls token generation. The scheduler (small batches, `Task.yield()` between them, longer yields while a generation stream is live) belongs to the engine, and it is the same loop that reports progress to whatever surface invoked it.

### 3.3 What "one engine, several model kinds" means concretely

A `ModelKind` on the loaded-model record, an embedder registry parallel to the existing `vlmTypes` allow-list, and **one** `EmbeddingEngine` actor that exposes exactly four verbs. Everything in Part 4 is a thin adapter over those four verbs:

```swift
actor EmbeddingEngine {
    // The whole capability surface. Every integration in Part 4 calls only these.
    func embed(texts: [String], role: Role, task: Task?, modelKey: String?, dim: Int?) async throws -> [[Float]]
    func search(query: String, collectionId: String, limit: Int, minScore: Float) async throws -> [Hit]
    func index(paths: [URL], collectionId: String, progress: (Int, Int) -> Void) async throws -> IndexReport
    func status() async throws -> EngineStatus          // models resident, collections, dims, queue depth, model keys
}
```

If a proposed surface needs anything other than these four, the surface is wrong, not the engine.

---

## Part 4 — The integration surfaces (the main deliverable)

The framing to honour, verbatim: *embeddings should be a lower-level capability — part of the engine that enables other things in the app, similar to tools or MCP. Ideally an embedding engine runs passively and can be called by tools, by the LLM directly, or through terminal/scripting, in line with how the app encourages agent access and utility.*

That framing maps onto infrastructure this app **already has**, and the design below is deliberately built out of existing parts rather than new ones. Three facts about our codebase decide the shape of everything that follows:

* **`/var/minis/**` is the shared surface** between app, guest and agent (`workspace`, `attachments`, `offloads`, `shared`, `skills`, `mcp-servers`…), and it is where an engine's artefacts must live to be reachable from every surface.
* **The app's own CLIs are not scripts — they are in-process, kernel-level interceptions** of `execve`. So "add a CLI" means "register a handler", and it is available to the shell, to scripts, to Python, and to the agent through `shell_execute` with zero new protocol.
* **MCP is an in-guest client with no app-side protocol implementation.** So "expose the engine over MCP" means "add a server entry", and the agent's existing MCP habit (`minis-mcp-cli`) picks it up for free.

### (a) MCP — what our implementation actually is, and whether we can serve one

**How MCP works in this app (read from source, not assumed):**

| Piece | File | What it does |
|---|---|---|
| Config model + store | `Agent/Session/MCPStore.swift` (900 lines) | `struct MCPServerConfig` with HTTP (`url`, `headers`, `oauth`) and STDIO (`command`, `args`, `env`, `startupTimeoutSeconds`) transport fields; `MCPStore.shared`; `isEnabledForSession(_:sessionId:)`; `importJSON(_:)`; `delete(id:)`. |
| On-disk config | `AIChatViewModel+RequestBudget.swift:306` `minisMcpServersPersistentDir` ⇄ `AIChatViewModel+Misc.swift:143` `minisMcpServersLinuxDir = "/var/minis/mcp-servers"` | `NablaConfig/mcp-servers/servers.json`, Claude-Desktop-compatible `mcpServers` object, symlinked into the App Group (`AIChatViewModel+Offloading.swift:900 ensureMinisSymlinks`). **The app and the in-guest CLI co-own this one file.** |
| OAuth | `Agent/Session/MCPOAuthDiscovery.swift`, `MCPOAuthController.swift` | Discovery + Keychain-held tokens for HTTP servers. |
| Debug RPC | `Debug/DebugRPCMCP.swift` | `debug.mcp.list` / `debug.mcp.import` / `debug.mcp.delete` — CRUD only. |
| **The actual MCP client** | `default_mount/usr/local/bin/minis-mcp-cli` → `/usr/local/lib/minis-mcp-cli/{main.py,daemon.py,transport/{stdio,http}.py,utils/{config,deps}.py}` | A POSIX, dependency-light Python implementation shipped byte-identically on iOS (iSH) and Android (PRoot). `daemon.py` is a forked long-lived process that binds an **ephemeral 127.0.0.1 TCP port** (iSH's fakefs cannot create an AF_UNIX socket inode — `bind()` → `EPERM`) and publishes it in `/tmp/minis-mcp-daemon.port`; per-server 10-minute idle TTL; 300 s RPC timeout; thread-per-connection. `transport/stdio.py` spawns the server with `subprocess.Popen([command]+args, stdin=PIPE, stdout=PIPE, stderr=DEVNULL)` and speaks **newline-delimited JSON-RPC** (`json.dumps(body) + "\n"`), *not* Content-Length framing. |
| Agent-loop routing | `AIChatViewModel.swift:5939` and `:6661` | `MCPStore.shared.systemPromptSnippet(for: sid)` is appended to the system prompt (and re-appended for helper/sub-agent turns with the parent's enablement). |
| The snippet itself | `MCPStore.swift:607` | `"Available MCP Servers (use minis-mcp-cli to discover and call):\n- <id>: <note>…\n\nTo use: run `minis-mcp-cli tools <server>` … then `minis-mcp-cli call <server> <tool> [args]`"` — Top-N (`Self.maxMetadataCount`) by `createdAt` desc, note capped at 200 chars. |
| Tool listing | `MCPStore.swift:644` `struct MCPToolInfo`, `:669 func refreshTools(server:)`, consumed only by `Views/MCP/MCPIntegrationsView.swift:239` | **Display only.** There is no conversion of MCP tools into `AgentToolDefinition` anywhere in the repo. |

**Answer to the question the task asks:** *does the agent loop already route MCP tools to the model?* **No — and that is good news.** MCP tools are never registered as native tools; the model is *told about servers* in the system prompt and reaches them with `minis-mcp-cli` through `shell_execute`. Therefore exposing our engine over MCP requires **no change to the agent loop, the tool registry, or the provider adapters** — it requires a server entry that the existing client can reach. Two ways, one of them proven:

**Option A (recommended) — an offload-backed STDIO MCP server.** The app registers a `minis-embed` handler that, when invoked with the `mcp` subcommand, speaks newline-delimited JSON-RPC on `stdin_fd`/`stdout_fd` (the pipe fds the offload API already hands the handler). Then `servers.json` gets one entry:

```json
{ "mcpServers": { "minis-embed": {
    "command": "/usr/local/bin/minis-embed",
    "args": ["mcp"],
    "env": {},
    "note": "On-device semantic search + embedding over files indexed on this iPhone. Tools: embed, semantic_search, index_status, embed_file." } } }
```

Why this specific shape works, all verified:
* **It is the identical mechanism to `apple-*`/`minis-*`.** `native_offload_add_handler("minis-embed", handler)` makes any `execve` on `/usr/local/bin/minis-embed` (or any path — `minis-*` names are exempt from the path-scope policy in `deps/ish/kernel/native_offload_policy.h`, which only constrains *generic* names like `ffmpeg`) call our handler in-process, with argv, translated CWD, and pipe-backed stdio.
* **`deps.ensure_command()` in the client `shutil.which`es the command**, so a purely virtual command would fail the pre-flight — and `NativeOffloadUtils.m:282` already gives us the fix: `noff_ensure_guest_stub("/usr/local/bin/minis-embed")` ("Create a stub executable in the guest filesystem so the shell can…"). Register the handler at boot **and** materialise the stub; then `which`, `shutil.which`, and `subprocess.Popen` all succeed and the execve lands in our handler.
* **stdout is the RPC channel, so nothing else may print to it.** The offload contract already enforces this discipline for `minis-mcp-cli` ("Diagnostics go to the log, never to stdout (stdout is reserved for the JSON the agent parses)"). Same rule here: diagnostics to `/var/minis/mcp-servers/mcp-cli.log` or stderr (which the client discards), protocol on stdout.
* **Cancellation is a first-class part of the handler API.** `native_offload_set_abort_handler(name, fn)` exists precisely because a handler that blocks forever pins the guest task (`ffmpeg` inside a VideoToolbox transcode is the cited case, `NativeOffloads/FFmpegOffload.m:507`). An `embed_file` over a 40-page PDF must be abortable, so implement it.
* **The tools are then exactly the ones the task names** — `embed`, `semantic_search`, `index_status`, `embed_file` — implemented as one `switch` on `params.name` over the same four engine verbs. Return MCP `content: [{type:"text", text: "<compact json>"}]`; for vectors, return a compact JSON array of floats (a 768-d f32 vector is ~7.5 KB of text — fine for one, not for a batch of 500; cap it, and for bulk work return a file path under `/var/minis/workspace/` and a summary).

**Option B — an in-app HTTP MCP server.** The app already binds a Darwin socket (`Debug/DebugServer.swift`, `socket(AF_INET, SOCK_STREAM)` → `bind` → `listen` on `0.0.0.0:8321`; API documented in `docs/specs/debug-server-api.md`), and the MCP client supports HTTP transport with headers + OAuth. So an HTTP endpoint at `http://127.0.0.1:<port>/mcp` is architecturally available and would additionally be reachable by *external* clients over the LAN. Two caveats: (i) **it needs auth** — an unauthenticated local HTTP surface that reads files is a bad idea, so reuse the `DebugAuth.swift` token pattern rather than inventing one; (ii) **guest→host loopback reachability is unverified** — the MCP daemon's own 127.0.0.1 listener is guest↔guest; whether the guest's socket layer can connect to a port bound by the *app process* is a question I could not settle from the source. **Check it in one command inside iSH before designing around it: `python3 -c "import socket;s=socket.create_connection(('127.0.0.1',8321),2);print('reachable')"`.** If that prints, Option B is a 20-line fallback with a much smaller blast radius.

**Do we want the server registered by default?** Yes, but carefully: `servers.json` is a single file co-owned by app and CLI, it is iCloud-synced per-server (`MCPServerItem`, `T-mcp-per-server-sync`), and the user can delete entries from the MCP screen. So seed `minis-embed` **idempotently** (only when absent, marked with a `note` that explains it is built in), and never resurrect it after an explicit delete.

### (b) A local CLI in the shared shell — `minis-embed` / `minis-search`

**Transport: the native offload mechanism. Not the debug server, not a socket, not a file protocol.** Concretely:

* Import `deps/ish/kernel/native_offload.h`; add `src/ios/NativeOffloads/EmbedOffload.{h,m}` exposing `void embed_offload_register(void)` (**one** handler, subcommand-dispatched — see the cap below); call it from the boot list in `src/ios/iSH/ISHKernel.m` step 9 ("Register native binary bindings", lines ~895-925, alongside `nlp_offload_register()` and `sessions_offload_register()`); materialise the stub with `noff_ensure_guest_stub("/usr/local/bin/minis-embed")`.
* **Hard constraint nobody has mentioned yet: the offload table is nearly full.** `#define NATIVE_OFFLOAD_MAX 32` (`native_offload.h:51`), the array is `offload_entries[NATIVE_OFFLOAD_MAX]` (`native_offload.c:78`), and there are **29 registered handlers today** (28 in release; `minis-hangtest` is debug-only). That is **3 free slots** (4 in release) — and exceeding it fails with `"native_offload: too many entries (max 32)"` and returns −1. **So: exactly one new registration, `minis-embed`, with `mcp` as a subcommand.** Do not register `minis-embed` *and* `minis-embed-mcp` *and* `minis-search`; that would consume the whole table and leave nothing for the next feature. This is a decisive design constraint, and it is also why the MCP server in (a) must be a subcommand of the same handler.
* **Argument shape** (POSIX-ish, in the house style of `noff_*` helpers):

```
minis-embed embed   [--text T | --text-file F | --stdin] [--role query|document]
                    [--task "search result"] [--dim 256] [--model KEY] [--batch]
minis-embed search  --query Q [--collection ID] [--limit 10] [--min-score 0.3] [--json]
minis-embed index   --path P [--path P2 …] [--collection ID] [--ext .md,.txt,.pdf]
                    [--progress] [--resume]
minis-embed status  [--json]
minis-embed mcp            # MCP stdio server (newline-delimited JSON-RPC) — see (a)
```
* Flags and output follow `NativeOffloadUtils`: `noff_find_arg`, `noff_has_flag`, `noff_get_subcommand`, `noff_parse_date`, `noff_json_envelope`, `noff_emit_json`, and the universal `--compact` / `-q`. Vectors come back as JSON float arrays; hits as `[{path,score,snippet,collection,model_key}]`; `--json` for machines, human text by default.
* **Exit codes are part of the interface**: `NOFF_EXIT_SUCCESS/ERROR/INVALID_ARGS/AUTH_DENIED/NOT_AVAILABLE`. A script that indexes a folder must be able to distinguish "no model installed" (`NOT_AVAILABLE`) from "that path is unreadable". Nothing else in the engine produces exit codes, so the CLI is where they get defined.
* **Reaching the engine from the handler:** the handler runs **on the guest thread**, synchronously, and must not block main and must not be `@MainActor`. The proven pattern in this codebase is `NativeOffloads/SessionsOffloadBridge.swift`: an `@objc` class whose static entry point hops into the actor with `DispatchSemaphore(value: 0)` + `Task.detached` and blocks the guest thread until the value arrives ("Called from the iSH guest thread (never main), so blocking is safe"). Copy it verbatim for `EmbedOffloadBridge.swift` → `EmbeddingEngine.embed/search/index/status`. **Add one thing it does not need but we do:** the bridge must not hold the semaphore across a long batch without pumping progress (write `\r`-style progress to stderr every N chunks), because the CLI's stdout is a TTY the user is watching.
* **Realism for a script inside iSH.** This works because the engine is in-process: no serialisation of the model, no client/server, no port. What is *not* realistic: (i) streaming binary vectors over the TTY (text only — use `--json`, or write a `.f32` blob to `/var/minis/workspace/` and return the path); (ii) a CLI invocation that runs for an hour while the user watches — the guest has a 10-minute command budget in the shell execution path, so `index` must be resumable and must report progress to a status file that a later `status` call reads; (iii) concurrent invocations — the engine serialises, so a second `minis-embed` blocks behind the first (which is correct, and should be reported, not hidden).
* **Permission surface.** `Agent/Offload/OffloadPermissionManager.swift` (~lines 126-146) holds the table of offload commands with `displayLabel`, `description`, `category` (`.privacy`/`.media`/`.system`), `showInSettings`. Today it lists `apple-*` commands only — **no `minis-*` row exists**. Since `minis-embed` reads arbitrary user paths, it should get a row (`category: .privacy`, `showInSettings: true`) so the user can see and revoke it; and because `AIChatViewModel+ConcurrentTools.swift` calls `OffloadPermissionManager.extractOffloadCommand(from:)` + `checkPermission(...)` on every `shell_execute`, adding the row also gives us per-session gating for free.
* **Prior art inside our own product:** `apple-nlp embed` already exists (`NativeOffloads/NLPOffload.m:321 cmd_embed`) and returns `NLEmbedding.word/<lang>` word vectors (300-d, closed vocabulary, per-word, no batching). So "an embedding command in the shell" is not new — what is new is a *sentence* vector, a *batch* path, a *persistent index* and a *retrieval* verb. Reuse its envelope and flag conventions (`--model`, `--text`, `--compact`, `-q`) so the two commands feel like one family, and consider making `minis-embed embed --model nlembedding` a zero-download fallback that delegates to the same `NLEmbedding` call.

### (c) An agent tool — declared retrieval in the middle of a turn

**Where tools are declared:** `Agent/Chat/AIChatViewModel+ToolDefinitions.swift` → `func makeAgentTools() -> [AgentToolDefinition]`. Today: `shell_execute`, `file_read`, `file_write`, `file_edit`, `browser_use`, `memory_write`, `memory_get`, `read_image` — with a **conditional-registration precedent** (`let includeMemoryTools = memoryEnabled`) that an embedding tool can follow (`includeRetrievalTools = engineReady`), so no model is ever offered a tool whose engine has no model installed. `AgentToolDefinition(name:description:parameters:required:propertyOrdering:)` and `AgentToolParam(type:description:enumValues:)` are the constructors to use.

**Where tools are executed:** `Agent/Chat/AIChatViewModel+ConcurrentTools.swift`, the `switch tu.name { case "shell_execute": … }` starting at line ~372, with `parseToolInput(from: argsJson)` for parsing. **Every new tool also needs:** a case in `AIChatViewModel+SSEStream.swift` at the three presentation switches (`makeToolSpeech` :1069, `makeToolPreview` :1107, `toolInputPreview` :1135) — otherwise the tool appears in the transcript as an unnamed block; a rule in `AIChatViewModel+ToolPreflight.swift:229 preflightValidateToolCall(name:…)`; and, if it should survive session reload/background helpers, cases in `ChatStore.swift` (~:1978, ~:5786) and `AIChatViewModel+BackgroundTask.swift:399`.

**Recommended shape: one tool, not three.** Call it `retrieval` (or `semantic_search` — I would use the latter: the model finds it from the name, and `browser_use` sets the precedent of one tool with an `action` enum):

```swift
AgentToolDefinition(
  name: "semantic_search",
  description: """
    Search the user's indexed files and notes on this iPhone by meaning, not keywords.
    Also embeds text on demand. Use it before answering questions about the user's own
    documents, and to find related material. Runs entirely on-device.
    """,
  parameters: [
    "action":  .string(enum: ["search", "embed", "status", "index"]),
    "query":   .string,          // search
    "text":    .string,          // embed
    "path":    .string,          // index
    "collection": .string, "limit": .integer, "minScore": .number, "dim": .integer,
    "tool_title": .string
  ], required: ["tool_title", "action"], …)
```

Same-registry note: because `Providers/LocalMLX/LocalMLXProvider.swift` consumes these same definitions and the local engine already does native tool calling (commit `ca388ea` forwards `ToolSpec` and surfaces `toolCallComplete`), **the retrieval tool works for on-device models too** — no provider-specific work.

**Why a declared tool matters more than it looks.** With only the CLI available, retrieval is something the model must *remember* to do, in a shell syntax it must get right, paying a round-trip. As a declared tool it is one call with a typed schema, its output is structured, and the failure mode ("no index yet, here is how to build one") can be *told* to the model in the tool description. Prior art agrees (see (f)): hosted `file_search`-style retrieval is adopted by models at a much higher rate than a CLI they must recall.

**Output discipline:** cap the hits returned inline (e.g. 8), include `score` + a 200-character snippet + `path`, and write the full result to `/var/minis/offloads/` returning the path — that is exactly the pattern `browser_use get_cookies` uses, and it keeps the transcript small.

### (d) Shortcuts / App Intents — what the engine must expose for them to work

`EMBEDDING-INTEGRATION.md` §1–2 already specifies the intents (`EmbedFileIntent`, `SemanticSearchIntent`, a local-model action), the iOS 26 modes (`supportedModes = .background`, phone-only execution target), the entity shapes to copy (`SendPromptResult`, `SessionEntity`+`EntityQuery`), and the two traps (`progress` must advance per chunk or the system cancels the background runtime; a resumable, idempotent job). I will not repeat it. What matters *here* is the single requirement it places on the engine:

> **The engine must expose one stable, async, surface-agnostic API that an intent, a tool, an MCP server and a CLI all call — and it must be cancellable, progress-reporting and idempotent at that boundary.**

Concretely, the four verbs in Part 3.3 plus three properties:

1. **Cancellation is cooperative at chunk granularity.** `EmbedFileIntent`'s `progress` callback and the SwiftUI/`.task` cancellation of a Shortcut must both land in the same place: the per-batch `Task.checkCancellation()` inside `index(paths:…)`. If progress and cancellation are separate mechanisms, an intent that the system kills mid-PDF leaves the index half-written. (Which is why `(content_hash, extractor_version)` as the blob key — already specified in the prior report — is a *correctness* requirement, not bookkeeping: it is what makes a re-run a no-op after a kill.)
2. **A poll-friendly status.** `GetSessionStatusIntent` already establishes the pattern "the long job runs in the app; the caller gets a handle and polls". `engine.status()` is the same idea and is also what `minis-embed status` reads — one implementation, two surfaces.
3. **Registration bookkeeping.** Any new long-running intent must call `ShortcutRunTracker.markPending/logPerformEntry/noteProgress/complete` (`Agent/Intents/ShortcutRunTracker.swift`) and `BackgroundKeepAliveManager.shared.armEagerlyForShortcut(sessionId:caller:)` **before its first `await`**, or the app's own diagnostics, Live Activity and keep-alive will not know a job is alive. And adding a shortcut to `MinisShortcutsProvider.swift` means adding a key to **every** `<locale>.lproj/AppShortcuts.strings` (legacy `.strings`, not `.xcstrings`, because the deployment target is iOS 16).

So the requirement is not "build an intent" — it is "do not let the intent own any logic". Every line of embedding logic lives behind `EmbeddingEngine`; the intent is an adapter.

### (e) Skills — could a `SKILL.md` describe retrieval usage, and should it?

**Mechanically yes, and it is nearly free.** Skills are directories under `/var/minis/skills/<name>/SKILL.md`, managed by `Agent/Session/SkillStore.swift`; the engine injects a *metadata fragment* into the system prompt — `skillPromptFragment(for:)` (`SkillStore.swift:1290`) — capped at `maxSkillMetadataCount` entries, prioritising bundled skills (`importSource == .bundled`), with per-session enablement (`isEnabledForSession`) and a Top-N ranking when there are more skills than fit. The model then loads a `SKILL.md` on demand — which is precisely how this very session works (the three bundled skills are visible in my own prompt, and I read `SKILL.md` files rather than being given their bodies).

**Should it?** Yes, but *for a different job than the tool*, and only after the argv/schema is frozen:

| | Tool (c) | Skill (e) |
|---|---|---|
| Effect | **Declared**: the model sees a typed schema and can call it | **Advisory**: prompt text explaining when/how to use a capability |
| Cost | Prompt tokens on **every** turn | Prompt tokens on every turn for the metadata line; the body only when loaded |
| Best at | "Do this one thing" | Multi-step workflows: *index a folder → search it → cite paths*, or the convention for where collections live (`/var/minis/shared/index/<collection>/`) |
| Failure mode | Unused if the description is vague | Ignored if it competes with many other skills (the Top-N cap) |

**Recommendation:** ship the **tool** as the enforcement mechanism, and add `skills/retrieval/SKILL.md` only if measurement shows the model needs procedural guidance the tool description cannot carry. Do not put the *schema* in the skill — a schema in prose is a bug factory. And ordinary users should not need the skill at all: if they do, the tool's description is wrong.

### (f) Prior art — how other agent apps expose retrieval to their own agent

Five distinct shapes exist, and it is worth being explicit about which one we are choosing.

1. **Retrieval as an MCP server** — the app's capability becomes a server the agent's client connects to. The MCP project's own reference servers are the canonical examples: **Memory** (`src/memory`, a knowledge-graph persistent memory system), plus **Filesystem**, **Fetch**, **Git**, **Sequential Thinking**, **Time** (`modelcontextprotocol/servers` README, read live). The lesson: the *project itself* models "capability the agent uses" as a local stdio server, which is exactly the shape in (a). Community vector servers (Chroma, LanceDB, mem0/OpenMemory memory servers) extend the same pattern to embeddings and vector stores [**names from general knowledge of the MCP ecosystem; verify each in the MCP Registry before citing them in a design doc** — the registry at `registry.modelcontextprotocol.io` is the authority now, and the repo README explicitly says it only hosts the reference servers].
2. **Retrieval as a first-class hosted tool** — OpenAI's `file_search` (with `file_search_call` in the Responses API) and Anthropic's server-side `web_search`: retrieval declared to the model, executed with citations, not delegated to the agent's own tooling. The lesson for us: **declaration beats improvisation** — this is the argument for (c) over (b)-alone.
3. **Retrieval as automatic context injection** — Cursor indexes the codebase and injects relevant context without a tool call; Continue offers an explicit `@codebase` reference alongside it. The lesson: passive injection gives the best average answer quality because it never depends on the model choosing, but it is expensive in tokens and unpredictable in latency. In *our* architecture its equivalent is the context-policy path (`Agent/Chat/ContextPolicy.swift`), and it is a plausible Phase-2 addition: when a session's message looks like a question about the user's files, pre-retrieve and attach — no tool call, no model decision.
4. **Retrieval as nothing at all** — Claude Code and similar CLI agents ship no embeddings and use `ripgrep` + MCP servers instead. Worth remembering as the honest baseline: **lexical search plus a shell is already powerful**, so the embedder must beat "grep plus a good file_read" on the tasks we claim, and the strongest early case is not code search but *cross-lingual, paraphrase, and multimodal* retrieval, which grep cannot do at all.
5. **App-hosted MCP servers** — an application exposing its *own* functionality to the agent as a server it starts itself. Nothing in the MCP spec forbids a client connecting to a server the same process hosts; in our implementation `MCPStore` accepts any STDIO `command`, and an offload-backed virtual binary *is* such a server. **This is the precedent that makes (a) legitimate rather than a hack.**

### (g) Ranked build order

Dependencies are real, not stylistic. Read the "depends on" column as a hard gate.

| # | Surface | Depends on | Unlocks | Cost |
|---|---|---|---|---|
| **0** | **Pin `mlx-swift-lm` to `main` ≥ `648693c`** (or a fork at that SHA), add the `MLXEmbedders` product | — (it is a prerequisite, not a surface) | Correct Gemma-family embedder masks (#654); component-aware text-only loading (#679/#580); reranker precision fixes. **Without this, every Gemma-based embedder silently returns causally-masked vectors.** | Half a day + CI |
| **1** | **The spec layer**: `EmbeddingSpec`, `EmbeddingSpecReader` (both `1_Pooling` schemas, `modules.json`, `sentence_bert_config.json` incl. the new modality shape, `config_sentence_transformers.json` prompts), `.minis-embed.json` written from `LocalModelStore.adopt(from:id:)`, `LocalModelKind.embedding`, an `embedderTypes` allow-list beside `vlmTypes` (`LocalModelStore.swift:272`), `EmbedderFactories.registerAll()` | 0 | **Everything else.** Pooling, prefix, dim, dtype, normalise, EOS policy, maxTokens, MRL dims. Nothing downstream can be built correctly before this, because every downstream component *consumes* these values. | 1–2 days, testable offline against MiniLM / bge-small / Harrier fixtures |
| **2** | **`EmbeddingEngine` actor + `EmbeddingHost` residency** (the four verbs; slotted residency: `generative` exclusive, `embedding` ≤2 budgeted; admission = weights + scratch, no KV term; `.reservation` wired ticket for resident weights) | 1 | Every surface below. Also the first honest answer to "can a 176 MB embedder coexist with a 2.4 GB chat model" — and `KVCacheStatus` (#639) gives us the real KV number to subtract. | 2–3 days |
| **3** | **`minis-embed` offload CLI** (one handler, subcommand dispatch, stub via `noff_ensure_guest_stub`, `EmbedOffloadBridge` on the `SessionsOffloadBridge` pattern, a permission row, exit codes) | 2 | **Immediate agent utility with zero prompt/tool work** — the model already has `shell_execute`. Also the fastest way for *us* to test the engine from a script, in shell, in Python, over `/var/minis/**`. | 1–2 days. **First surface to build** because it needs no UI, no prompt, no intent, and it makes everything else debuggable. |
| **4** | **MCP server entry** (`minis-embed mcp` subcommand speaking newline-delimited JSON-RPC; four tools; abort handler; idempotent seed into `servers.json`; `MCPStore` note text) | 2 (and the same handler as 3 — do not add a second offload registration; the table has 3 free slots) | Third-party and user-scripted retrieval; the existing MCP screen makes it visible and revocable; **no agent-loop change**. | +0.5–1 day on top of 3. Cheapest real win after the CLI. |
| **5** | **Agent tool `semantic_search`** (definition + dispatch + 3 presentation switches + preflight, conditional registration) | 2; 5 code sites in `AIChatViewModel+*` | Declared, mid-turn retrieval for remote *and* local models. Highest quality-per-turn, but it touches the most files and changes prompt size for every turn. | 1–2 days |
| **6** | **Shortcuts / App Intents** (`EmbedFileIntent`, `SemanticSearchIntent`, shortcut + all locale `.strings`) | 2 (and the spec layer for the entity fields) | Background indexing; cross-app automation; the passive/always-on story. | 2–3 days incl. localization keys |
| **7** | **Skills** (`skills/retrieval/SKILL.md`) | 3–5 (freeze the argv/schema first) | Procedural guidance only. | Hours |

**Everything depends on the spec layer and the engine actor — say it plainly.** There is no surface on this list that can be built correctly without (1) and (2); the surfaces are *adapters*, and an adapter built before the thing it adapts is a rewrite waiting to happen. The one exception is that the *CLI* can be stubbed against a hardcoded `NLEmbedding`/`apple-nlp embed` path on day one to prove the offload + bridge + stub mechanics end-to-end before the engine exists — that is a good smoke test of the plumbing, and it is how I would sequence the first day of surface work.

**Ordering rationale in one line:** spec → engine → shell → MCP → tool → Shortcuts → skill, because each step's cost is paid once and each step's benefit is immediately visible to the agent, while the two steps that touch the agent loop (5) and the OS (6) come after the two that touch nothing (3, 4).

---

## Appendix A — the concrete change list

**Vendored dependency**
* `deps/` (SwiftPM): `mlx-swift-lm` → `main` at `648693c6fcb9ec84405112b6d2fec384eae582b8` (or fork); add product `MLXEmbedders`; optional branch dependency for PR #684 behind a flag.

**App — model library / spec layer**
* `Providers/LocalMLX/LocalModelStore.swift`: `enum LocalModelKind { case text, vision, embedding, unsupported }`; `static let embedderTypes: Set<String>` (seed: `bert`, `roberta`, `xlm-roberta`, `distilbert`, `nomic_bert`, `qwen3`, `lfm2`, `gemma3`, `gemma3_text`, `gemma3n`, `embedding_gemma2`, `embedding_gemma2_text`); extend the `kind` computation at `:225`; write `.minis-embed.json` beside `.looplab.json` in `adopt(from:id:)` (`:302-336`).
* New `Providers/LocalMLX/EmbeddingSpec.swift` + `EmbeddingSpecReader.swift` (both `1_Pooling` schemas; new `sentence_bert_config.json` modality shape; ST 6.x `modules.json` paths; prompts from `config_sentence_transformers.json`; `maxTokens` from the card).
* New `Providers/LocalMLX/EmbeddingEngine.swift` (actor, four verbs), `EmbeddingHost.swift` (slotted residency), `EmbeddingIndex.swift` (`emb_models`/`emb_blobs`/`emb_vectors` in one SQLite file).
* `Providers/LocalMLX/LocalModelHost.swift`: second slot kind; subtract resident-embedding bytes from generative admission; keep `Memory.cacheLimit` untouched.

**App — surfaces**
* New `src/ios/NativeOffloads/EmbedOffload.{h,m}` (`embed_offload_register`, one handler, subcommands `embed|search|index|status|mcp`, `native_offload_set_abort_handler`), `EmbedOffloadBridge.swift` (semaphore + `Task.detached`), register in `src/ios/iSH/ISHKernel.m` step 9, stub via `noff_ensure_guest_stub`.
* `Agent/Offload/OffloadPermissionManager.swift`: one `minis-embed` row (`category: .privacy`, `showInSettings: true`).
* `Agent/Session/MCPStore.swift`: idempotent built-in server seed (`minis-embed` → `command: "/usr/local/bin/minis-embed", args: ["mcp"]`, explanatory `note`).
* `Agent/Chat/AIChatViewModel+ToolDefinitions.swift` (+`makeAgentTools`), `+ConcurrentTools.swift` (dispatch), `+SSEStream.swift` (3 switches), `+ToolPreflight.swift` (validate), `ChatStore.swift` (persist/UI), `+BackgroundTask.swift` (helpers).
* `Agent/Intents/EmbedFileIntent.swift`, `SemanticSearchIntent.swift`, `EmbedResult.swift`, `CollectionEntity.swift`, `EmbeddingModelEntity.swift`, `MinisShortcutsProvider.swift` + every `<locale>.lproj/AppShortcuts.strings`.
* `skills/retrieval/SKILL.md` (later).

**Guest**
* `/usr/local/bin/minis-embed` stub (created by `noff_ensure_guest_stub`, no file to maintain in `default_mount`).
* No change to `minis-mcp-cli` / `daemon.py` — that is the point of choosing the offload-stdio shape.

## Appendix B — what I could not determine (and what to check)

| Question | How to check |
|---|---|
| **Does swift-transformers append the EOS/EOS-equivalent for Harrier (270m `add_eos_token: true`) and for the 0.6b (no flag, eos `<\|im_end\|>`)?** This decides the last-token vector and is the single highest-risk Harrier unknown. | Encode one fixed sentence through `MLXEmbedders` with and without an explicit EOS and compare cosine against sentence-transformers/TEI for both models. Record in the spec as `appendEosToken` with `provenance = "measured"`. |
| **Is the guest's `127.0.0.1` able to reach a port the app binds?** If yes, MCP-over-HTTP is a cheap fallback. | `python3 -c "import socket;s=socket.create_connection(('127.0.0.1',8321),2);print('reachable')"` inside iSH. |
| **Does `MLXEmbedders`' `Qwen3Model` `sanitize` handle a sentence-transformers Qwen3 checkpoint** (key prefix `model.`, no `lm_head`, tied embeddings)? | Load `microsoft/harrier-oss-v1-0.6b` and read the missing/unexpected-key warnings; compare a vector against the card's example. |
| **Does Harrier-270m's `EmbeddingGemma` handler path return the last-token vector we expect with `sliding_window_pattern: 1`?** (MLX computes `isSliding = (layerIdx+1) % pattern != 0`, i.e. all-global for pattern 1, which agrees with the all-`full_attention` `layer_types`.) | Assert single-text vs batched equality and diff against the reference vector; if they disagree, the discrepancy is in mask selection, not pooling. |
| **Harrier MRL support** — the task asked; the cards and files are silent. | Treat as unsupported. If we want a 256-d index, measure recall against 640/1024 first; do not assume it. |
| **Whether MLX fp16 quantisation of EG2 hits the same RMSNorm overflow FluidInference saw in Core ML** (cosine 0.95 → 0.9996 with a max-abs pre-scale). | Load bf16 first; if we quantise, diff against the bf16 reference on 50 texts before shipping. Google's rule ("do not use float16") is the floor, not the answer. |
| **Whether PR #684 merges.** `mergeable_state: blocked` = review gating, not conflict; Apple (`davidkoski`) has been engaging, and #580 — the same author, and the dependency #684 rebased onto — merged 2026-10-12, hours before this report. | Watch #684; either way, vendoring the branch is safe because its `EmbeddingModel` surface (`pooledOutput`, `poolingStrategy = .none`) is the shape our spec layer already expects. |
| Whether the `nabla-` vs `minis-` naming in `MCPStore.systemPromptSnippet` matters for new tool descriptions. | Non-issue: the repo's source strings are pre-rebrand (`scripts/rebrand_nabla.py`), the shipped binary is `minis-mcp-cli`, and the live prompt says `minis-mcp-cli`. Match whatever the rebrand produces. |

## Appendix C — sources

**Repositories (read live this session)**
* `ml-explore/mlx-swift-lm` — `main` @ `648693c6fcb9ec84405112b6d2fec384eae582b8`; tag `3.32.3` @ `3b339ad`; `Libraries/MLXEmbedders/{ModelFactory.swift, Pooling.swift, Models/Gemma3.swift, Models/Qwen3.swift, EmbedderModelContainer.swift, README.md}`; `Libraries/MLXLMCommon/{ModelComponent.swift, ModelCheckpoint.swift, CheckpointComponent.swift, KVCache.swift, WiredMemoryPolicies.swift}`; `Libraries/MLXLLM/LLMModelFactory.swift`; `skills/mlx-swift-lm/references/{embeddings.md, wired-memory.md, model-container.md}`; `Package.swift`.
* GitHub API via the `github` MCP: `get_latest_release`, `list_releases`, `list_tags`, `pull_request_read` (`get`, `get_files`) for #684, #654, #580, #679, #685, #690, #642.
* The app: `src/ios/Agent/Session/MCPStore.swift`, `src/ios/Debug/DebugRPCMCP.swift`, `src/ios/Debug/DebugServer.swift`, `src/ios/Agent/Chat/AIChatViewModel+{ToolDefinitions,ConcurrentTools,SSEStream,ToolPreflight,Offloading,RequestBudget,Misc,BackgroundTask}.swift`, `src/ios/Agent/Offload/OffloadPermissionManager.swift`, `src/ios/Agent/Session/SkillStore.swift`, `src/ios/Providers/LocalMLX/{LocalModelStore,LocalModelCatalog,LocalModelDownloader,LocalModelHost}.swift`, `src/ios/NativeOffloads/*` (esp. `NLPOffload.m`, `SessionsOffload.m`, `SessionsOffloadBridge.swift`, `NativeOffloadUtils.{h,m}`, `FFmpegOffload.m`), `src/ios/iSH/ISHKernel.m`, `src/ios/default_mount/usr/local/{bin/minis-mcp-cli,lib/minis-mcp-cli/**}`, `docs/specs/ios-sandbox-ish-summary.md`.
* iSH fork: `deps/ish/kernel/{native_offload.h, native_offload.c, native_offload_policy.h, native_offload_policy.c, native_offload_sym_builtins.c, exec.c}`.
* Prior research extended (not repeated): `/var/minis/shared/research/embeddings/{EMBEDDING-GEMMA-2.md, EMBEDDING-INTEGRATION.md, EMBEDDINGS-LANDSCAPE.md}`.

**Models (fetched live)**
* `google/embeddinggemma-2` @ `914f7f89…`: `config.json`, `README.md` (card), `1_Pooling/config.json`, `2_Normalize/config.json`, `modules.json`, `sentence_bert_config.json`, `config_sentence_transformers.json`, `chat_template.jinja`, `processor_config.json`, and the HF model API with `?blobs=true` for exact file sizes.
* `microsoft/harrier-oss-v1-270m` @ `31de22b6…` and `microsoft/harrier-oss-v1-0.6b` @ `f9b9dc8d…`: `config.json`, `README.md`, `1_Pooling/config.json`, `modules.json`, `config_sentence_transformers.json`, `tokenizer_config.json`.
* `modelcontextprotocol/servers` README (reference-server list, read live).
* PR #684 discussion (cosine parity claims, the iPhone 14 Pro text-only measurement cited in `EMBEDDING-GEMMA-2.md` §3.1).
