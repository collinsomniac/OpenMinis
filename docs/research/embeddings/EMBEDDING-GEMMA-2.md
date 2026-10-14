# EmbeddingGemma 2 and running embedding models on iPhone with MLX Swift

**Research date:** 2026-10-12 · **Target:** Minis iOS fork, Swift, iOS 27, iPhone 17 Pro Max (A19-class), `mlx-swift-lm` 3.32.3 + `mlx-swift` 0.32.3

**Bottom line up front**

1. **EmbeddingGemma 2 is real**, released **2026-10-06**. It is a *natively multimodal* encoder (text+code+image+video+audio → one 768-d space), a different animal from the text-only 300M *EmbeddingGemma* (2025-09-04). Total 740M params, but the **text/code tower alone is 270M** and is separately loadable.
2. **MLX Swift cannot run EmbeddingGemma 2 today at 3.32.3.** `MLXEmbedders` exists and is mature, and it *does* support EmbeddingGemma **1** (`model_type: gemma3_text`), but the registry has no `embedding_gemma2` entry. An **open, unmerged PR — [mlx-swift-lm#684](https://github.com/ml-explore/mlx-swift-lm/pull/684)** — adds exactly this, with verified parity (cosine 0.9998+) and a real iPhone 14 Pro measurement (208 s / 1000 docs @512 tok, text-only 4-bit ~176 MB).
3. **There is a live correctness bug at our pin.** `mlx-swift-lm` 3.32.3's `EmbeddingGemma` uses **causal** attention; the model needs **bidirectional**. Fixed only on `main` by PR #654 (2026-10-07), unreleased. Do not ship EmbeddingGemma on 3.32.3.
4. **Cheapest path to a working second model kind today:** `mlx-community/embeddinggemma-300m-4bit` (**173 MB**) — loads with the existing `MLXEmbedders` code path, no new model code, provided we bump to a revision containing PR #654.
5. **Best path for EmbeddingGemma 2 text-only:** cherry-pick/vendor PR #684, strip vision+audio tensors → **~176 MB** working set. Full multimodal 4-bit is **1.098 GB** and is *not* a sensible co-resident model on a phone.
6. **Apple's built-in shortcut is weak.** `NLEmbedding` word embeddings are 300-d and English-centric with a **closed vocabulary**; `sentenceEmbedding(for:)` exists but has no published dimension/quality and no batch API. Not a competitor to a real encoder — usable only as a zero-download fallback.
7. **A Core ML/ANE path already exists and is better than MLX for this specific job** on latency: `FluidInference/embeddinggemma-2-coreml` runs the text tower 100% on the Neural Engine, 512 tokens in **27.4 ms on M5 Pro**, with a published Swift manager.

---

## 1. EmbeddingGemma 2 — what was actually released

### 1.1 Release facts

| Item | EmbeddingGemma (v1) | EmbeddingGemma 2 |
|---|---|---|
| Release date | **2025-09-04** | **2026-10-06** |
| Source | [ai.google.dev/gemma/docs/releases](https://ai.google.dev/gemma/docs/releases) | same page; [blog.google](https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2/) |
| Base architecture | Gemma 3 | **Gemma 4** |
| HF repo | `google/embeddinggemma-300m` (**gated**, needs auth to fetch raw files) | `google/embeddinggemma-2` (open, 115.7k downloads / 1.9k likes as of 2026-10-12, created 2026-09-14, last modified 2026-10-06) |
| License | `license:gemma` — **Gemma Terms of Use** | **Apache 2.0** |
| Docs | [ai.google.dev/gemma/docs/embeddinggemma](https://ai.google.dev/gemma/docs/embeddinggemma) | same page |
| Downloads (claimed by Google) | >20M | n/a |

The docs page now describes v2 as the headline model and demotes v1 to "Previous Versions". The license change (Gemma ToU → Apache 2.0) is the single biggest build-relevant delta and is stated explicitly at [ai.google.dev/gemma/docs/embeddinggemma](https://ai.google.dev/gemma/docs/embeddinggemma): *"provided with open weights and licensed under the Apache 2.0 License, allowing you to fine-tune and deploy it in your own projects"*. Note the model card's license link points at `https://ai.google.dev/gemma/docs/gemma_4_license` while labelling it Apache 2.0 — the HF tag is `license:apache-2.0`, which is the tag to trust. [minor ambiguity noted]

### 1.2 Parameter counts and modular loading

| Configuration | Params | Notes |
|---|---|---|
| Text/code only | **270M** = 130M backbone + 140M embedder | 140M "embedder" ≈ 134.2M token-embedding table (262,144 × 512) + 6.3M 512→768 projection |
| + Vision | 440M (+170M) | images, visual documents, PDFs, slides, charts, video frames |
| + Audio | 570M (+300M) | raw 16 kHz mono audio, Gemma 4 USM conformer, 12 layers |
| Full multimodal | **740M** | all encoders, shared 768-d space |

Sources: [model card](https://huggingface.co/google/embeddinggemma-2) ("740M total, combining a 270M parameter text model with modular vision (170M) and audio (300M) encoders"), [developer guide](https://developers.googleblog.com/en/embeddinggemma-2-the-developer-guide/).

Encoders are selectable at load time (`config_kwargs={"vision_config": None, "audio_config": None}` in sentence-transformers; `loadVision: false, loadAudio: false` in the MLX Swift PR). **Cross-config embeddings are interchangeable** — a query embedded with the 270M text-only setup matches documents embedded with the full model.

### 1.3 Text-tower architecture (from `config.json`)

Source: [`google/embeddinggemma-2/config.json`](https://huggingface.co/google/embeddinggemma-2/raw/main/config.json) — outer `model_type: embedding_gemma2`, inner `text_config.model_type: embedding_gemma2_text`.

| Property | Value |
|---|---|
| Layers | 24 |
| Model / hidden dim | 512 |
| Intermediate (FFN) | 2,048 |
| Heads / KV heads | 4 / 2 |
| head_dim | 256 — **but `per_layer_config` overrides layers `05`, `11`, `17`, `23` to head_dim 512, kv_heads 1** |
| Local:global attention | 5:1 — `layer_types` = 5× `sliding_attention` then 1× `full_attention`, repeating |
| Sliding window | 512 tokens |
| RoPE | `full_attention`: θ=1e6; `sliding_attention`: θ=1e4 |
| Activation | gated FFN, `gelu_pytorch_tanh` |
| `hidden_size_per_layer_input` | 512 (**per-layer input embedding block, Gemma-4 style, present in every layer**) |
| vocab_size | 262,144 |
| `embedding_dim` (output) | **768** |
| `max_position_embeddings` | 262,144 in config — but the documented/usable context is **8,192** |
| Token ids | bos 2, eos 1, pad 0, image 258880, `<|audio|>` 258881 / 258882 / 258883, boa 256000 / boi 255999 |
| Pooling | **mean pooling** over non-pad tokens |
| Projection | 512 → 768 linear, then L2 normalize |
| Embedding scale | inputs multiplied by **√512 ≈ 22.627417** before the transformer (confirmed independently in the Core ML conversion's `config.json`) |

### 1.4 Context, dimensions, languages

| Property | EmbeddingGemma 1 | EmbeddingGemma 2 |
|---|---|---|
| Context | 2,048 tokens | **8,192 tokens** (4×) |
| Native dim | 768 | 768 |
| MRL truncation | 768 / 512 / 256 / 128 | 768 / 512 / 256 / 128 |
| Languages | "over 100" | "over 100" (text/code); training data spans 140+ languages |
| Modality token budgets | n/a | image 280 tok ≈ 29 images; video 140 tok/frame ≈ 58 frames @1 fps; audio 25 tok/s ≈ 327 s |

MRL quality table (768d full quality, from the [model card](https://huggingface.co/google/embeddinggemma-2)):

| Dim | Compression | MTEB ml v2 | MTEB eng v2 | MTEB Code v1 | MIEB lite | MMEB v2 | MSEB | MAEB |
|---|---|---|---|---|---|---|---|---|
| 768 | 1:1 | 61.36 | 68.46 | 78.68 | 64.64 | 59.01 | 69.54 | 49.39 |
| 512 | 1:1.5 | 61.17 | 68.41 | 77.24 | 64.32 | 58.38 | 69.18 | 49.21 |
| 256 | 1:3 | 60.41 | 67.78 | 76.18 | 63.13 | 56.24 | 66.76 | 48.91 |
| 128 | 1:6 | 57.89 | 65.68 | 71.41 | 59.06 | 45.65 | 56.71 | 46.92 |

Practical read: **256d is near-lossless for text/code** (61.36→60.41) and ~95% of full quality for image/video/speech. **128d loses ~25% of multimodal quality** (MMEB 59.01→45.65) — text-only workloads only. Google's own guidance: 128d "Large text-only indexes and first-stage shortlisting". **Re-normalize after truncating** — slicing a unit vector does not preserve unit length and silently degrades ranking.

### 1.5 Benchmarks — variant and date

| Benchmark | Variant | Metric | EG2 | EG1 |
|---|---|---|---|---|
| MTEB (multilingual) | **v2**, Mean(Task) | Multiple | 61.36 | 61.15 |
| MTEB (English) | **v2**, Mean(Task) | Multiple | 68.46 | — |
| MTEB (code) | **v1**, Mean(Task) | NDCG@10 | 78.68 | 68.76 |
| MIEB (image) | **lite** | Mean(TaskType) | 64.64 | — |
| MMEB v2 Image / VisDoc / Video | v2 | Hit@1 / NDCG@5 / Hit@1 | 57.28 / 67.84 / 50.67 | — |
| MSEB (sound) | Retrieval | MRR@10 | 69.54 | — |
| MAEB (audio) | — | Mean(Task) | 49.39 | — |

**All figures are from the model card published at release on 2026-10-06**, full-precision checkpoint. Google's blog headline is "**+9.92 points on MTEB Code** (68.76 → 78.68)". Note the multilingual text score barely moves vs. v1 (61.36 vs 61.15) — the wins are code and multimodality, not monolingual retrieval. [The exact MTEB run date/commit is **not published** — [unverified]; treat the numbers as vendor-reported.]

### 1.6 Task prefixes — load-bearing, identical in shape to v1

Confirmed from **two independent sources**: the [model card](https://huggingface.co/google/embeddinggemma-2) and the Core ML conversion's shipped [`config.json`](https://huggingface.co/FluidInference/embeddinggemma-2-coreml/raw/main/config.json).

| Use case | Type | v2 prompt name | Query prefix | Document prefix |
|---|---|---|---|---|
| Web / document search | asymmetric | `SearchQuery` | `task: search result \| query: {q}` | `title: {title} \| text: {content}` |
| Question answering | asymmetric | `QuestionAnswering` | `task: question answering \| query: {q}` | `title: {title} \| text: {passage}` |
| Fact checking | asymmetric | `FactChecking` | `task: fact checking \| query: {claim}` | `title: {title} \| text: {evidence}` |
| Code search | asymmetric | `CodeRetrieval` | `task: code retrieval \| query: {q}` | `title: {file} \| text: {code}` |
| Classification | symmetric | `Classification` | `task: classification \| query: {c}` | — |
| Clustering | symmetric | `Clustering` | `task: clustering \| query: {c}` | — |
| Similarity | symmetric | `SentenceSimilarity` | `task: sentence similarity \| query: {c}` | — |

Hard requirements for a from-scratch implementation:

- **`prompt_name="Document"` expands to `title: none | text: `** when there is no title. Titled documents must be formatted manually as `title: {t} | text: {c}`. The Core ML config stores the document default literally as `"title: none | text: "`.
- **Media inputs get NO prefix.** Prefixes apply to text only.
- Prefixes are **not injected by the tokenizer or the model** — the caller must prepend them. The MLX Swift PR's own README says so explicitly: *"It does not add task prefixes: use `task: search result | query: ` for retrieval queries and `title: none | text: ` for documents without titles."*
- Omit the prefix and it still runs, but precision drops.

Token sequence convention (verified in the Core ML conversion's audio `text_sequence`): `<bos> …tokens… <eos>`, with `pad_token_id = 0` for right padding. For media: `<bos> <|image|> [soft tokens] <image|> <eos>`.

### 1.7 Is a sentence-transformers wrapper required?

**No — but the wrapper is the reference.** Three ways to consume it:

1. **sentence-transformers ≥ 6.1.0** (`pip install -U sentence-transformers[image,audio,video] transformers`) — this is what Google documents. It supplies prefixing, pooling, projection, normalization, truncation and MM processing.
2. **Transformers directly** — architecture class is `EmbeddingGemma2Model` in the HF `transformers` library; video support was **new in v5.18** (the mlx-vlm conversion pins `transformers>=5.18.0`).
3. **Plain forward pass** — feasible for text-only. There is no separate "embedder head" module to reproduce beyond: `embed_tokens → ×√512 → 24 blocks → final RMSNorm → Linear(512→768) → mean-pool over non-pad → L2 normalize`. The Core ML conversion implements exactly this and documents its parity: *"mean pooling over tokens, then normalization"*, cosine **1.000000** (fp32 wrapper) and ≥0.9984 (fp16) vs sentence-transformers.

There is a **wrapper-style config dir** in the HF repo (`1_Pooling/`, `2_Normalize/`, `modules.json`, `sentence_bert_config.json`) — MLX Swift's `loadPooling()` reads `1_Pooling/config.json`, but the PR overrides this to `.none` pooling because the model does pooling internally.

### 1.8 What is actually new in the "2"

| Change | Detail |
|---|---|
| Architecture generation | Gemma 3 decoder → **Gemma 4 decoder** (encoder-only usage) |
| Per-layer inputs | `hidden_size_per_layer_input = 512` — a `per_layer_model_projection` (512 → 24×512), gated per-layer input blocks, `post_per_layer_input_norm`. **This does not exist in Gemma 3 and is the single biggest porting obstacle.** |
| Per-layer attention shape overrides | `per_layer_config` gives layers 05/11/17/23 head_dim 512 / kv_heads 1 while all others are head_dim 256 / kv_heads 2 |
| Attention masking | Driven by an explicit `layer_types` array (`sliding_attention` / `full_attention`) rather than v1's integer `sliding_window_pattern` |
| Value normalization | `v_norm` = `RMSNormNoScale` on V (new) |
| Attention scale | `scale = 1.0` in SDPA with pre-scaled Q (per mlx-vlm's port) — no separate `query_pre_attn_scalar` key in the v2 config |
| Modality encoders | Vision: Gemma 4 ViT, 16 layers, 2-D RoPE, 3×3 pooling. Audio: Gemma 4 USM conformer, 12 layers, 1024 hidden, chunked/local attention (`attention_context_left 13 / right 0`), 10 s window → 250 tokens |
| Shared tokenizer + audio encoder with Gemma 4 | Explicit memory win when co-deployed with a Gemma 4 chat model |
| Context | 2K → 8K |
| Explicit base-footprint reduction | 300M → 270M for text/code |
| License | Gemma ToU → Apache 2.0 |

**Teacher / distillation:** the blog says EmbeddingGemma 2 is "Built from the same technology as Gemini Embedding models", and the model card's training-data section confirms multimodal pre-training with a **January 2025** cutoff. **No publicly documented teacher model, distillation recipe, or training paper was found** — I could not locate an arXiv paper for EmbeddingGemma 2 or v1. [unverified — treat any teacher/distillation claim as unsourced.]

---

## 2. Can we run it with MLX Swift?

### 2.1 What `MLXEmbedders` is and what it contains

`MLXEmbedders` is a **first-party Apple library inside `mlx-swift-lm`** (not a separate package). It was introduced on **2026-02-12** (first commits touching `Libraries/MLXEmbedders`), and is **present at our pinned tag `3.32.3`** — verified by fetching `Libraries/MLXEmbedders/ModelFactory.swift` and `Models/Gemma3.swift` at ref `3.32.3` (both HTTP 200).

Repo: <https://github.com/ml-explore/mlx-swift-lm> · library README: <https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/README.md>

Files at `main`: `AttentionMask.swift`, `EmbedderModelContainer.swift`, `EmbeddingModel.swift`, `Extensions/`, `ModelFactory.swift`, `Models/`, `Pooling.swift`, `Reranker.swift`.

Model implementations at `main`: `Bert.swift`, **`Gemma3.swift`**, `LFM2Bidirectional.swift`, `NomicBert.swift`, `Qwen3.swift`.

### 2.2 Type registry (authoritative list)

From [`ModelFactory.swift`](https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/ModelFactory.swift):

| `model_type` | Implementation | Family |
|---|---|---|
| `bert`, `roberta`, `xlm-roberta`, `distilbert` | `BertModel` | BERT |
| `nomic_bert` | `NomicBertModel` | NomicBERT |
| `qwen3` | `Qwen3Model` | Qwen3 |
| `lfm2` | `LFM2BidirectionalModel` | LFM2.5 embedding + ColBERT |
| **`gemma3`, `gemma3_text`, `gemma3n`** | **`EmbeddingGemma`** | **Gemma 3 / EmbeddingGemma 1** |

Rerankers are supported through the same factory (`isSequenceClassification` branch; `bge-reranker-v2-m3` is registered).

### 2.3 Does it support Gemma-family embedders?

**Yes — but only the Gemma-3-generation ones, i.e. EmbeddingGemma 1.** `EmbeddingGemma` in `Models/Gemma3.swift` is a from-scratch port of `mlx_lm/models/gemma3_text.py` (Apple's source comment) that:

- decodes `Gemma3Configuration` from `config.json`, transparently unwrapping a `text_config` key (VLM checkpoints),
- applies the `× √hidden_size` embedding scale,
- supports sliding-window vs. global attention,
- implements **mean pooling over non-padding tokens**, an optional `dense.0`/`dense.1` projection head (hidden size inferred from the checkpoint), and **L2 normalization**,
- remaps `language_model.*` prefixes and truncates padded vocab,
- filters `lm_head` and `rotary_emb.inv_freq`.

It is **not** BERT-only, but it is **not** Gemma-4-aware.

### 2.4 ⚠️ The version trap at our pin (3.32.3)

`EmbeddingGemma-1`'s config carries `"use_bidirectional_attention": true` (verified in [onnx-community/embeddinggemma-300m-ONNX/config.json](https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX/raw/main/config.json)). At tag **3.32.3**, `Gemma3.swift` does **not decode that key at all** and always builds a causal mask.

- Bug report: [mlx-swift-lm#638 — "[BUG] EmbeddingGemma uses causal attention although the model is bidirectional"](https://github.com/ml-explore/mlx-swift-lm/issues/638) (closed)
- Fix: [PR #654 — "MLXEmbedders: use bidirectional attention in EmbeddingGemma"](https://github.com/ml-explore/mlx-swift-lm/pull/654), merged to `main` **2026-10-07** — i.e. **after** the 3.32.3 release cut (2026-09-30).
- Consequence: on 3.32.3, EmbeddingGemma embeddings are computed with a **causal** mask and a symmetric half-window (`slidingWindow / 2`) is impossible. Quality is silently degraded. **We must bump to a revision ≥ #654 before shipping any Gemma embedder.**

Related history worth knowing: [#223 fixed init-order crash + dense-head hidden size](https://github.com/ml-explore/mlx-swift-lm/pull/223) (landed in 3.31.4, the release that shipped working EmbeddingGemma), and [#580 "Load model components on demand"](https://github.com/ml-explore/mlx-swift-lm/pull/580) merged 2026-10-12 (lets text-only users skip unneeded towers).

### 2.5 Does it support EmbeddingGemma **2**? No — but a PR does

At `main` (2026-10-12) there is **no `embedding_gemma2` / `embedding_gemma2_text` entry** in `EmbedderTypeRegistry`, and no `MLXEmbedders/Models/EmbeddingGemma2.swift`. **MLX Swift cannot load EmbeddingGemma 2 today, at any released tag.**

**The work already exists: [PR #684 — "Add EmbeddingGemma 2 full support"](https://github.com/ml-explore/mlx-swift-lm/pull/684)** by `aleroot`.

| Field | Value |
|---|---|
| State | **open, not merged, not draft** |
| Created / updated | 2026-10-07 / 2026-10-12 (active) |
| Branch | `aleroot:alessio/public-gemma4-vision-encoder` |
| Size | +3,464 / −610 across 9 files |
| Review state | "Review required", 5/5 checks; Apple maintainer (`davidkoski`) is engaged |
| Self-reported parity | cosine **0.9999** (audio/video/interleaved), **0.99995** at 2,880 and 7,490 tokens, vs. the Transformers SDPA path that sentence-transformers uses |

Files changed (from the PR patch):

| File | Change |
|---|---|
| `Libraries/MLXEmbedders/ModelFactory.swift` | +7 — registers `"embedding_gemma2"` and `"embedding_gemma2_text"` → `EmbeddingGemma2`; adds `EmbedderRegistry.embeddinggemma2 = ModelConfiguration(id: "mlx-community/embeddinggemma-2-bf16")` |
| `Libraries/MLXEmbedders/Models/EmbeddingGemma2.swift` | +24 — `extension EmbeddingGemma2: EmbeddingModel`, `poolingStrategy = .none`, `maxPositionEmbeddings = 8192`, truncates input, returns `pooledOutput` (note: `hiddenStates` is always `nil` — a reported footgun) |
| `Libraries/MLXEmbedders/Pooling.swift` | +2 — `if model is EmbeddingGemma2 { return Pooling(strategy: .none) }` |
| `Libraries/MLXLMCommon/Models/EmbeddingGemma2.swift` | +741 — shared core + `embed(inputIds:attentionMask:)`, `imageFeatures`, `audioFeatures` |
| `Libraries/MLXLMCommon/Models/Gemma4Encoders.swift` | +1,099 — Gemma 4 vision/audio towers |
| `Libraries/MLXVLM/EmbeddingGemma2.swift` | +751 — `EmbeddingGemma2Embedding` actor: `.text/.image/.audio` inputs, task enum, `dimensions:` MRL truncation, `loadVision/loadAudio` flags |
| `Libraries/MLXVLM/Models/Gemma4.swift` | +15 / −610 — refactor onto the shared encoders |
| `Tests/MLXLMTests/EmbeddingGemma2Tests.swift` | +763 |
| `Libraries/MLXEmbedders/README.md` | +62 — Swift usage |

**Swift API after the PR** (verbatim shape from the PR's README diff):

```swift
import MLXEmbedders

let container = try await EmbedderModelFactory.shared.loadContainer(
    from: #hubDownloader(), using: #huggingFaceTokenizerLoader(),
    configuration: EmbedderRegistry.embeddinggemma2)

let vector = try await container.perform { context in
    let ids = context.tokenizer.encode(text: "task: search result | query: What causes the northern lights?")
    let output = context.model(MLXArray(ids)[.newAxis], positionIds: nil,
                               tokenTypeIds: nil, attentionMask: nil)
    let pooled = context.pooling(output, normalize: true)
    try MLX.checkedEval(pooled)
    return pooled.asArray(Float.self)
}
```

Multimodal + MRL path:

```swift
let embeddings = try await EmbeddingGemma2Embedding(
    modelDirectory: directory, tokenizerLoader: #huggingFaceTokenizerLoader())
let vector = try await embeddings.embed(
    .init([.text("Product demo: "), .image(.url(imageURL)), .audio(.url(audioURL))]),
    task: .document, dimensions: 256)
```

**Coexistence design we should copy for our "second kind of model":** the existing `MLXEmbedders` container API (`EmbedderModelFactory.shared.loadContainer` → `EmbedderModelContainer.perform { context in … }`, `context.tokenizer` / `context.model` / `context.pooling`) is exactly the shape we want. `EmbedderModelContainer` is `Sendable` and serialises access via a `SerialAccessContainer`. Text truncation respects `maxPositionEmbeddings`, which is how we avoid an encoder eating the whole context window at the chat model's expense.

### 2.6 If we have to do the port ourselves (fallback plan)

The PR may stall. What a port involves, concretely:

| Module | Work |
|---|---|
| `MLXEmbedders/Models/EmbeddingGemma2.swift` | Thin `EmbeddingModel` conformance (the 24-line wrapper above) |
| `MLXEmbedders/ModelFactory.swift` | Two registry keys + a `ModelConfiguration` constant |
| New core (or extend `Models/Gemma3.swift`) | 24-layer Gemma-4 decoder: per-layer input projection/gate/norm blocks, `v_norm` (`RMSNormNoScale`) on V, per-layer `head_dim`/`kv_heads` overrides via `per_layer_config`, mask selection from `layer_types`, RoPE θ per layer type, `× √512` scale, final RMSNorm, `Linear(512→768)`, mean pool over non-pad, L2 norm |
| Language side (Python reference) | [`mlx_vlm/models/embedding_gemma2/language.py`](https://github.com/Blaizzy/mlx-vlm/tree/main/mlx_vlm/models/embedding_gemma2) is a **complete, working MLX Python implementation** (`TextModel`, `PerLayerInputs`, `PerLayerBlock`, `EncoderLayer`, `Attention`, `MLP`, `RotaryEmbedding`) — directly portable line by line. `mlx_lm/models/gemma4_text.py` / `gemma4.py` in [ml-explore/mlx-lm](https://github.com/ml-explore/mlx-lm/tree/main/mlx_lm/models) are the upstream reference for the Gemma-4 decoder body. |
| Tokenizer | Reuse `swift-transformers`; vocab 262,144, same tokenizer as Gemma 4 |

**There is no `embedders` module in `mlx-lm` (Python)** — I verified the package tree: `mlx_lm/` contains `models/`, `quant/`, `tuner/`, `tool_parsers/`, etc., **no `embedders/`**, and `mlx_lm/models/` has `gemma.py gemma2.py gemma3.py gemma3_text.py gemma3n.py gemma4.py gemma4_text.py recurrent_gemma.py` but no embedding-specific Gemma file. MLX Swift's `MLXEmbedders` was ported from [`taylorai/mlx_embedding_models`](https://github.com/taylorai/mlx_embedding_models) (stated in its README footnote), which also has no Gemma-4/EmbeddingGemma-2 model. The only Python MLX reference for EmbeddingGemma 2 is `Blaizzy/mlx-vlm`. [So: the task's premise of "mlx-lm's Python `embedders` module has a Gemma model we could port" is **not accurate** — `mlx-lm` has no embedders module. The real references are `mlx-vlm` and the EGGUF/GGML + HF-transformers implementations.]

**PyPI packages:**

| Package | Latest | Relevance |
|---|---|---|
| `mlx-embeddings` | 0.1.0 (from `Blaizzy/mlx-embeddings`) | models: `bert, colidefics3, colqwen2_5, gemma3_text, lfm2, llama_bidirec, llama_nemotron_vl, modernbert, openai_privacy_filter, qwen3, qwen3_vl, siglip, xlm_roberta`. **No embedding_gemma2.** Note `gemma3_text.py` exists → EmbeddingGemma 1 only. |
| `mlx-lm` | 0.32.0 | no embedders module |
| `mlx-vlm` | 0.7.6, **has `mlx_vlm/models/embedding_gemma2/`** | the only Python MLX implementation of EmbeddingGemma 2; the `mlx-community` conversions were produced from revision `3d87e884` on branch `pc/embeddinggemma-2` |

### 2.7 Apple's native stack — the zero-download shortcut

#### `NLEmbedding` (NaturalLanguage)

Reference: <https://developer.apple.com/documentation/naturallanguage/nlembedding> · guide: <https://developer.apple.com/documentation/naturallanguage/finding-similarities-between-pieces-of-text>

| Aspect | Finding |
|---|---|
| Available since | iOS 13 (class), `sentenceEmbedding(for:)` documented as available broadly; Scripting's guide says iOS 14+ for sentence embeddings |
| `wordEmbedding(for:)` dimension | **300** — *empirically verified on this device*: `apple-nlp embed --text "…"` returns `"model": "NLEmbedding.word/en"` with `"dimension": 300` per token |
| `sentenceEmbedding(for:)` dimension | **512** — widely reported but **not documented by Apple and not measurable from this environment** [**unverified**]. The `apple-nlp` CLI exposes only the word embedding (every `--model` value falls back to `NLEmbedding.word/en`). |
| Vocabulary | Word embeddings have a **closed vocabulary**: out-of-vocabulary terms return `vector == nil`. In my run, "This" returned `null` while "northern"/"sun" returned vectors. Sentence embeddings are dynamic and have no fixed vocabulary. |
| Languages | Word embeddings for "a number of languages"; Scripting's guide notes `wordEmbedding("en")` "is the most reliably available embedding. Other languages may return null depending on OS revision." |
| Usable for semantic search? | Sentence embeddings work for paraphrase/retrieval scoring (`distance(between:and:)`, cosine in [0,2]). But: **no batch API**, **no Matryoshka dims**, **no published benchmark**, **no task prefixes**, and the docs warn: *"A single NLEmbedding instance isn't safe for concurrent use… calling them on one instance from multiple threads or tasks at the same time can crash your app."* Useful as a **zero-download fallback / cold-start default**, not as our production embedder. |
| Custom embeddings | You can compile your own via Create ML `MLWordEmbedding` or `writeEmbeddingForDictionary:…`, and load with `init(contentsOf:)`. |

**Verdict:** `NLEmbedding` is a *shortcut that needs no download* and is worth wiring as a fallback, but it is not competitive on quality, has no MRL, and no batching. Google/MLX/Core ML are the real options.

#### Core ML `.mlpackage` (ANE-friendly)

Two independent ANE-oriented conversions already exist for EmbeddingGemma 2:

| Repo | Contents | Size | Performance | Source |
|---|---|---|---|---|
| [`FluidInference/embeddinggemma-2-coreml`](https://huggingface.co/FluidInference/embeddinggemma-2-coreml) | `EmbeddingGemma2Text.mlpackage` (ML Program, fp16, 7 fixed-shape functions sharing weights) + `embeddings.bf16` (262,144×512 bf16 = **256 MB**) + tokenizer + audio/vision mlpackages | Text **271 MB** (+256 MB table); audio 561 MB; vision 292 MB | **100% ANE** (3,862/3,862 ops). 512 tok = **27.4 ms**; 32 tok = 2.6 ms; `pack_256` batches 8 texts → **644 texts/s** (single: 307/s) on M5 Pro. Swift manager: `EmbeddingGemma2Manager` in [FluidInference/FluidUse](https://github.com/FluidInference/FluidUse) | README + config.json |
| [`anemll/anemll-embeddinggemma-2-ane`](https://huggingface.co/anemll/anemll-embeddinggemma-2-ane) | Core AI `.aimodel` packages, separate per tower | text 290.9 MB, vision 307.2 MB, audio 588.6 MB, host 268 MB | M4 Pro ANE: text ~35 ms / sentence, audio 11–26 ms, image ~414 ms | README |

Critical Core ML notes for a build:

- **Requires iOS 18+** for multifunction ML Programs (we are on iOS 27 — fine).
- **Fixed shapes are mandatory for ANE.** Variable-length (enumerated) shapes put the whole graph on the CPU. `S ∈ {32,48,64,128,256,512}`; longer inputs are truncated — FluidInference reports capping at 512 tokens "changed nothing measurable" on their set, because **at ≤512 tokens every sliding-window layer sees the whole sequence**, so a padding mask is all the model needs.
- **fp16 is dangerous in the raw model**: the card reports activations reaching ~2,000 and *squaring* them inside RMSNorm overflows fp16 (plain fp16 RMSNorm: cosine **0.95** vs reference). Their conversion divides by row max-abs first → **0.9996**. **If we port to MLX in fp16, we must replicate this.**
- First load on device compiles all functions for ANE and **takes several minutes once** (cached afterwards) — a real UX consideration.
- ANE latency scales with the *square* of the vision patch count (full attention over patches), so the GPU beats ANE for images despite 100% ANE placement.

**Recommendation:** for text-only embeddings the Core ML/ANE route is **~3× faster than the MLX route** at 512 tokens on comparable hardware (27.4 ms vs. 208 ms measured on the iPhone 14 Pro MLX path — different SoCs, so treat as indicative, not apples-to-apples), but MLX keeps **one runtime, one weight format, one memory story** alongside the chat model. Given we already ship `mlx-swift-lm`, **MLX first; Core ML as a later optimisation if embedding latency becomes user-visible.**

---

## 3. Measured and expected performance on an A19-class iPhone

### 3.1 Real measurement (iPhone 14 Pro, A16, 6 GB) — EmbeddingGemma 2 text-only 4-bit

From [@rurza's comment on PR #684](https://github.com/ml-explore/mlx-swift-lm/pull/684), 2026-10-11 — text tower only, `mlx-community/embeddinggemma-2-4bit` with all vision/audio tensors removed, plain tokenizer, no processor:

| Metric | Value |
|---|---|
| Weights on disk | **~176 MB** |
| Load time | **0.59 s** |
| Throughput @512 tok | **~208 s per 1,000 documents → 4.81 docs/s** |
| Peak footprint | **~391 MB** |
| Quality parity vs. transformers on dequantized weights | cosine min **0.9998** / mean **0.9999** (short + 512-tok); **0.99997** at 1k/2k/4k tokens |
| Batched vs. one-by-one (3/15/512/4000 tok, right-padded) | ≥ **0.99994** |
| Retrieval quality (31 docs, 32 queries, Polish/English) | MRR **0.94**, cross-lingual **0.90** — identical to full-precision sentence-transformers |

Reported caveats: (a) stale `vision_config`/`audio_config` keys in `config.json` break loading with missing weights; (b) `hiddenStates` is always `nil`; (c) input is hard-cut at 8,192 tokens.

### 3.2 Memory footprint by quantisation (EmbeddingGemma 2)

"Text-only" sizes are for the 270M text tower; "full" includes both media towers.

| Build | Source | On-disk | Text-only? | Expected resident + MLX buffers |
|---|---|---|---|---|
| bf16, full multimodal | [mlx-community/embeddinggemma-2-bf16](https://huggingface.co/mlx-community/embeddinggemma-2-bf16) | **1,489 MB** | no | ~1.9–2.1 GB peak |
| 8-bit, full | [mlx-community/embeddinggemma-2-8bit](https://huggingface.co/mlx-community/embeddinggemma-2-8bit) | **1,234 MB** | no | ~1.5–1.8 GB peak |
| 6-bit, full | [mlx-community/embeddinggemma-2-6bit](https://huggingface.co/mlx-community/embeddinggemma-2-6bit) | 1,166 MB | no | ~1.5 GB peak |
| 4-bit affine, full | [mlx-community/embeddinggemma-2-4bit](https://huggingface.co/mlx-community/embeddinggemma-2-4bit) | **1,098 MB** | no | ~1.4–1.6 GB peak |
| MXFP4, full | [mlx-community/embeddinggemma-2-mxfp4](https://huggingface.co/mlx-community/embeddinggemma-2-mxfp4) | 1,090 MB | no | ~1.4 GB peak |
| **4-bit affine, text only** | mlx-community 4-bit with media tensors stripped | **~176 MB** | **yes** | **391 MB measured (A16)** → expect ~380–450 MB on A19 |
| bf16, text only | [jayyun98/embeddinggemma-2-text-270m-mlx-bf16](https://huggingface.co/jayyun98/embeddinggemma-2-text-270m-mlx-bf16) / [gahabeen/…](https://huggingface.co/gahabeen/embeddinggemma-2-text-270m-mlx-bf16) | 542 MB | yes | ~750–900 MB peak |
| Q8_0, text only | [ggml-org/embeddinggemma-2-GGUF](https://huggingface.co/ggml-org/embeddinggemma-2-GGUF) | 310 MB | yes | n/a (not MLX) |
| UD-Q4_K_XL, text only | [unsloth/embeddinggemma-2-GGUF](https://huggingface.co/unsloth/embeddinggemma-2-GGUF) | **175.7 MB** | yes | n/a (not MLX) |
| q4f16, text only | [onnx-community/embeddinggemma-2-ONNX](https://huggingface.co/onnx-community/embeddinggemma-2-ONNX) | 156.9 MB | yes | n/a (not MLX) |
| Core ML fp16 text | [FluidInference/embeddinggemma-2-coreml](https://huggingface.co/FluidInference/embeddinggemma-2-coreml) | 271 MB + 256 MB table | yes | ~530 MB |
| LiteRT (Android-class devices) | [litert-community/embeddinggemma-2-text-270m-litert-lm](https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm) | 199.5–416.4 MB (per-SoC) | yes | per-SoC |

Google's own on-device claim ([DeepMind blog](https://deepmind.google/blog/embeddinggemma-2-an-open-lightweight-multimodal-embedding-model/), Pixel 11 Pro): **~191 MB active RAM quantised for text-only weights, ~567 MB for the full multimodal model.** That is *active* RAM and excludes MLX's buffer pool, which is why our measured peak (391 MB) is ~2× the weight size.

**Coexistence budget check.** A 4-bit chat model of 1B ≈ 700 MB resident, 4B ≈ 2.4 GB. iPhone 17 Pro Max ships with 12 GB of RAM [**reported** — [unverified], Apple does not publish RAM]. iOS jetsam for a foreground app typically allows several GB. So:

| Scenario | Encoder | Chat model | Combined peak | Verdict |
|---|---|---|---|---|
| 4B chat + EG2 text-only 4-bit | ~0.4 GB | ~2.4 GB | **~2.8 GB** | ✅ comfortable |
| 4B chat + EG1 300M 4-bit | ~0.35 GB | ~2.4 GB | ~2.8 GB | ✅ comfortable |
| 4B chat + EG2 full multimodal 4-bit | ~1.5 GB | ~2.4 GB | ~3.9 GB | ⚠️ workable but wasteful — strip the towers |
| 4B chat + EG2 text-only bf16 | ~0.85 GB | ~2.4 GB | ~3.3 GB | ⚠️ 4-bit is strictly better here |

**Design rule: text-only, 4-bit, ~176 MB, loaded on demand, evicted when the chat model needs memory.** The 134M-param token table is 268 MB in bf16 by itself — quantising the embedding matrix is what makes an encoder co-resident at all.

### 3.3 Embedding throughput on A19 — estimate with reasoning

**Method: analytic FLOPs → divide by the assumed effective quantised throughput of 3.8 TFLOP/s.**

FLOPs per document (batch 1, encoder forward), `≈ 2 × P_non-embed × S` plus quadratic attention:

- EG2 text tower, non-embedding params: 740M total − 134.2M `embed_tokens` = **~136M** (consistent with the card's "130M backbone"). Sanity check by layer: attention ≈ 42M (20 layers × 1.57M + 4 layers × 2.62M), MLP ≈ 76M (24 × 3×512×2048), per-layer-input blocks ≈ 19M (6.3M projection + 2×6.3M gates).
- Attention terms: 20 sliding layers × 2·2·S²·1024 + 4 global layers × 2·2·S²·2048.

| Workload | Linear GFLOP | Attention GFLOP | Total GFLOP/doc | ms/doc @3.8 TFLOP/s | **docs/s** |
|---|---|---|---|---|---|
| EG2 text, S=512 | 139.3 | 30.1 | **169.4** | 44.6 | **≈ 22** |
| EG2 text, S=256 | 69.6 | 7.5 | 77.1 | 20.3 | ≈ 49 |
| EG2 text, S=128 | 34.8 | 1.9 | 36.7 | 9.7 | ≈ 103 |
| EG1 300M, S=512 (P_non-emb ≈ 107M) | 109.6 | 25.8 | 135.4 | 35.6 | ≈ 28 |

**Cross-check against the only hard measurement we have.** The iPhone 14 Pro result (169.4 GFLOP / 0.208 s) implies an **effective 0.81 TFLOP/s** on A16 for this workload. Scaling by the A19/A16 ratio implied by our 3.8 TFLOP/s assumption (3.8 / 0.81 ≈ 4.7×) is optimistic for a real generational step; a **conservative 3–4×** gives **15–19 docs/s**.

**Estimate to plan with (marked as estimate):** **~15–25 docs/s at 512 tokens**, best single figure **≈ 20 docs/s**, for EmbeddingGemma 2 text-only 4-bit on an A19-class iPhone 17 Pro Max. Short chunks are much cheaper: **~80–100 docs/s at 128 tokens**. This is consistent with the Core ML ANE path (512 tok in 27.4 ms = 37 docs/s on M5 Pro), which is the same order of magnitude.

**Memory-bandwidth sanity check (batch 1):** ~176 MB of int4 weights must be streamed per document. At ~68 GB/s (LPDDR5X, A19 Pro class), that is a **2.6 ms/document floor → ≈ 385 docs/s ceiling**. At 512 tokens we forecast 44.6 ms, i.e. 0.176 GB / 0.0446 s ≈ **3.9 GB/s** of effective bandwidth demand — ~17× below the ceiling, so the encoder is **compute-bound at batch 1, not bandwidth-bound**. (At 128 tokens it is ~18 GB/s — still under the ceiling, i.e. still compute-bound, but the margin shrinks.) Corollary: **batching helps throughput only modestly** for a 270M encoder on a phone; the win from batching is latency amortisation, not weight amortisation. For a 1M-document corpus, at 20 docs/s that is **~14 hours** of sustained embedding — budget for it (background/suspended work, or a smaller-threshold "index what's visible" policy).

**Why not just use the 0.6B chat model as an embedder?** A 0.6B causal LM at 4-bit (~350 MB) can produce last-token embeddings, but it costs ~2× the FLOPs per token of the 270M encoder and is trained for generation, not retrieval — and it cannot be bidirectional. Keep them separate; that is what "a second kind of model" buys us.

---

## 4. What to download first to test

### 4.1 Ranked download list

| # | HF repo id | Format | Size | Requires | Proves |
|---|---|---|---|---|---|
| **1** | **`mlx-community/embeddinggemma-300m-4bit`** | MLX safetensors, 4-bit g=64, `model_type: gemma3_text` | **173 MB** (+33 MB tokenizer) | `mlx-swift-lm` at a revision containing PR #654 (bidirectional fix) | **End-to-end pipeline with ZERO new model code** — download → `EmbedderModelFactory` → vector → cosine ranking. This is the smallest thing that proves the pipeline. |
| 2 | `mlx-community/embeddinggemma-300m-8bit` | MLX 8-bit | 327 MB | same | Quality ceiling for the v1 family without a bf16 download |
| **3** | **`mlx-community/embeddinggemma-2-4bit`** | MLX 4-bit affine g=64, all four encoders | **1,098 MB** | **PR #684 vendored** | EmbeddingGemma 2 text path. Strip `vision_tower.*` / `audio_tower.*` tensors + the `vision_config`/`audio_config` keys → **~176 MB** text-only |
| 4 | `jayyun98/embeddinggemma-2-text-270m-mlx-bf16` (or `gahabeen/…`, same 542 MB payload) | MLX bf16, text tower only, `model_type: embedding_gemma2` | 542 MB | PR #684 vendored | Clean text-only checkpoint with no stale media config to strip — **the least-friction way to run EG2 text**. Quantise it to 4-bit ourselves if size matters |
| 5 | `FluidInference/embeddinggemma-2-coreml` | Core ML mlpackage | 271 MB text + 256 MB table | iOS 18+, `EmbeddingGemma2Manager` from [FluidInference/FluidUse](https://github.com/FluidInference/FluidUse) | ANE path; the fastest text-only option and a useful oracle for MLX numerics |
| 6 | `ggml-org/embeddinggemma-2-GGUF` (`embeddinggemma-2-Q8_0.gguf`, 310 MB) | GGUF | 310 MB | llama.cpp | Ground truth for tokenizer/prefix handling; `llama-server` gives a reference embedding to diff against (useful because `google/embeddinggemma-2` is reproducible only through HF) |

### 4.2 The single smallest pipeline-proving download

**`mlx-community/embeddinggemma-300m-4bit` — 173 MB.**

Rationale: it is (a) the smallest MLX-format embedder that is *actually* an EmbeddingGemma, (b) loadable **today** by the pinned `MLXEmbedders` code with a one-line `ModelConfiguration(id:)` — no new Swift, (c) `bert`-sized alternatives like `TaylorAI/bge-micro-v2` (~17 MB) and `sentence-transformers/all-MiniLM-L6-v2` (~90 MB) are smaller and already in `EmbedderRegistry`, but they would **not** exercise the Gemma-3 forward path, the mean-pooling + dense-projection + L2-normalisation chain, the `×√hidden_size` embedding scale, the bidirectional mask, or the 512-token sliding window. Pick `bge-micro-v2` only if the goal is to validate plumbing (download, cache, `perform`, UI), not the Gemma path.

**Do this in order:**
1. `/var/minis/workspace/openminis` → bump `mlx-swift-lm` to a revision ≥ PR #654 (`main` at 2026-10-07 or later) — **mandatory**; 3.32.3 gives causally-masked, degraded embeddings.
2. Add `MLXEmbedders` as a product dependency and load `mlx-community/embeddinggemma-300m-4bit` via a manual `ModelConfiguration`. Write a test asserting cosine similarity of a `task: search result | query: …` against a `title: none | text: …` document beats a shuffled control.
3. Vendor PR #684 (or wait for merge). Load `mlx-community/embeddinggemma-2-4bit`, strip the media towers, and diff against the Core ML or GGUF build on ~50 texts. Expect cosine ≥ 0.998.
4. Only then decide on multimodality. Media towers turn a 176 MB model into a 1.1 GB one and are a separate product decision.

### 4.3 Quantisation quality loss — what is actually measured

| Quant | Claimed/measured quality loss | Source |
|---|---|---|
| MLX 4-bit (EG2 text, vs. dequantized reference) | cosine min 0.9998 / mean 0.9999 @512; 0.99997 @1k–4k; **MRR 0.94 unchanged vs. full precision** | [PR #684 comment](https://github.com/ml-explore/mlx-swift-lm/pull/684) |
| MLX (EG1, from `mlx-community`) | **no published measurement found** [unverified] | — |
| Core ML fp16 (vs. torch fp32 sentence-transformers) | cosine ≥ 0.9984, mean 0.99996 over 562 posts | [FluidInference card](https://huggingface.co/FluidInference/embeddinggemma-2-coreml) |
| Core ML fp32 wrapper | cosine 1.000000 | same |
| GGUF (unsloth UD-Q4_K_XL etc.) | **no MTEB/recall numbers published** — the Unsloth README mirrors Google's model card and only adds "Unsloth Dynamic 3.0 achieves superior accuracy" (vendor claim) [unverified] | [unsloth card](https://huggingface.co/unsloth/embeddinggemma-2-GGUF) |
| Ollama text-only tags | none published; sizes only: `270m-nvfp4-text` 378 MB, `270m-mxfp8-text` 442 MB, `270m-bf16-text` 574 MB | [ollama tags](https://ollama.com/library/embeddinggemma-2/tags) |

Note the quantisation policy used by the `mlx-community` conversions: *text encoder and audio projection are quantised; **vision and audio towers and the vision projection stay BF16*** — which is exactly why even the 4-bit full build is 1.1 GB. **If size matters, build our own text-only conversion rather than stripping tensors at runtime.**

### 4.4 Ollama reference (for benchmarking only)

`ollama.com/library/embeddinggemma-2` exposes 17 tags including `270m` (378 MB), `440m` (714 MB), `570m` (990 MB), `740m`/`latest` (1.3 GB), plus modality-suffixed MLX variants. Ollama reports a **256K context window** for all of them, which contradicts the 8,192 usable limit in Google's documentation — an Ollama metadata artefact, not a capability. Do not treat it as a spec.

---

## 5. Open questions / things I could not verify

| Item | Status |
|---|---|
| Exact MTEB evaluation date and harness commit for the published EmbeddingGemma 2 scores | [unverified] — vendor-reported on the model card, no run metadata |
| Any training/distillation paper for EmbeddingGemma 2 (teacher model, recipe) | **Not found** — no arXiv paper located for either v1 or v2 |
| `NLEmbedding.sentenceEmbedding(for: .english).dimension` | [unverified] — commonly cited as 512; Apple does not document it and the `apple-nlp` CLI exposes only the 300-d word embedding |
| `google/embeddinggemma-300m` raw file contents | **Gated** — requires HF auth; architecture facts were cross-checked against the un-gated `onnx-community/embeddinggemma-300m-ONNX` config instead |
| iPhone 17 Pro Max RAM | [unverified] — reported as 12 GB; Apple does not publish it |
| MLX 4-bit quality loss specifically for EmbeddingGemma 1 | [unverified] — no published measurement found |
| Whether PR #684 will merge (and in which release) | Open, actively reviewed by Apple (`davidkoski`) as of 2026-10-12 16:41 UTC; #580 (component loading) was merged the same day at the maintainer's request, which suggests forward momentum |
| Was `hiddenStates: nil` intended in the PR's `EmbeddingModelOutput`? | Reported as a footgun by a user on the PR; the PR author has not yet responded |

---

## 6. Source index

**Google / model**
- <https://ai.google.dev/gemma/docs/embeddinggemma>
- <https://ai.google.dev/gemma/docs/releases>
- <https://developers.googleblog.com/en/embeddinggemma-2-the-developer-guide/>
- <https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2/>
- <https://deepmind.google/blog/embeddinggemma-2-an-open-lightweight-multimodal-embedding-model/>
- <https://huggingface.co/google/embeddinggemma-2> · <https://huggingface.co/google/embeddinggemma-2/raw/main/config.json>
- <https://huggingface.co/google/embeddinggemma-300m> (gated)

**MLX Swift**
- <https://github.com/ml-explore/mlx-swift-lm>
- <https://github.com/ml-explore/mlx-swift-lm/tree/3.32.3/Libraries/MLXEmbedders> (verified present at our pin)
- <https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/ModelFactory.swift>
- <https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/Models/Gemma3.swift>
- <https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/EmbeddingModel.swift>
- <https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/Pooling.swift>
- <https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/EmbedderModelContainer.swift>
- <https://github.com/ml-explore/mlx-swift-lm/blob/main/Libraries/MLXEmbedders/README.md>
- <https://github.com/ml-explore/mlx-swift-lm/pull/684> (EmbeddingGemma 2 — OPEN)
- <https://github.com/ml-explore/mlx-swift-lm/pull/654> (bidirectional fix — unreleased)
- <https://github.com/ml-explore/mlx-swift-lm/issues/638> (causal-attention bug)
- <https://github.com/ml-explore/mlx-swift-lm/pull/223> · <https://github.com/ml-explore/mlx-swift-lm/pull/580>

**MLX Python**
- <https://github.com/Blaizzy/mlx-vlm/tree/main/mlx_vlm/models/embedding_gemma2>
- <https://github.com/ml-explore/mlx-lm/tree/main/mlx_lm/models> (no embedders module; has `gemma4_text.py`)
- <https://github.com/Blaizzy/mlx-embeddings> · <https://pypi.org/project/mlx-embeddings/>
- <https://github.com/taylorai/mlx_embedding_models> (origin of MLX Swift's MLXEmbedders)

**Quantised builds**
- MLX: `mlx-community/embeddinggemma-2-{bf16,8bit,6bit,5bit,4bit,mxfp4,nvfp4,mxfp8}`, `mlx-community/embeddinggemma-300m-{4bit,5bit,6bit,8bit}`, `jayyun98/embeddinggemma-2-text-270m-mlx-bf16`
- GGUF: <https://huggingface.co/ggml-org/embeddinggemma-2-GGUF> · <https://huggingface.co/unsloth/embeddinggemma-2-GGUF>
- ONNX: <https://huggingface.co/onnx-community/embeddinggemma-2-ONNX> (q4 174 MB) · <https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX> (q4f16 175 MB)
- Core ML/ANE: <https://huggingface.co/FluidInference/embeddinggemma-2-coreml> · <https://huggingface.co/anemll/anemll-embeddinggemma-2-ane> · <https://github.com/FluidInference/FluidUse>
- LiteRT: <https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm>
- Ollama: <https://ollama.com/library/embeddinggemma-2/tags>

**Apple native**
- <https://developer.apple.com/documentation/naturallanguage/nlembedding>
- <https://developer.apple.com/documentation/naturallanguage/finding-similarities-between-pieces-of-text>
- <https://scriptingapp.github.io/guide/Device%20Capabilities/NaturalLanguage/Embedding>
