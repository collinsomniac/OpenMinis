# Embedding Models & Their Uses — Landscape Report for an On-Device iOS AI Assistant

**Prepared:** 2026-10-12 · **Audience:** product/eng deciding whether embeddings become a first-class tooling capability
**Target app:** Minis — iOS chat/agent app, LLMs on-device via MLX Swift, with a persistent memory system (files + keyword/fuzzy `memory_get`), a `skills/` folder of SKILL.md instruction sets, `offloads/` for large tool outputs, a `workspace/` of files, image/audio/video attachments, MCP tool servers, and a bookmark/URL store.

**Sourcing method.** All MTEB numbers below were pulled live from the **MTEB Leaderboard v1 API** (`https://mteb-leaderboard-backend.hf.space/v1/...`, `/openapi.json` documents it) on 2026-10-12 — benchmark `/scores` endpoints plus `/v1/models` for per-model metadata (license, `memoryUsageMb`, `embeddingDim`, `maxTokens`, release date). Model sizes marked *(measured)* come from the Hugging Face API `?blobs=true` file listing (sum of `.safetensors` bytes) on the same date. Model-card quotes come from the cards themselves. Anything I could not verify from a primary source is tagged **[unverified]**.

**Benchmark-version warning — read before comparing any two numbers.** MTEB has several incompatible suites. `MTEB(Multilingual, v1)` and `MTEB(Multilingual, v2)` are *different task sets* and scores are **not** comparable across them; the same is true of `MTEB(eng, v1)` vs `(eng, v2)`. Vendor blog posts are inconsistent about which they quote. Every score in this report is tagged with its suite. Where a vendor quoted a number, I say so.

---

## 1. Model landscape

### 1.1 Dense text embedders

`MLX` column: **yes** = a working `mlx-community/…` or vendor conversion exists; **reg** = listed in MLX Swift's `EmbedderRegistry` (`ml-explore/mlx-swift-lm`, `Libraries/MLXEmbedders/ModelFactory.swift`); **via arch** = architecture is in MLX Swift's `ModelFactory` registry (`bert`, `roberta`, `xlm-roberta`, `distilbert`, `nomic_bert`, `qwen3`, `lfm2`, `gemma3`, `gemma3_text`) so it should load, but the specific checkpoint is untested **[unverified]**; **no** = nothing published.

| Model (repo id) | Params | Dims | Matryoshka | Max ctx | Languages | License | ≈4-bit | ≈8-bit | MLX | MTEB (suite) | Phone? |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `google/embeddinggemma-2` | 740M total (270M text + 170M vision + 300M audio) | 768 | **yes** 128/256/512/768 | 8,192 | 100+ | **Apache-2.0** | ~1.10 GB (measured) · **165 MB LiteRT text-only** · 485 MB LiteRT full | ~1.23 GB (measured) | yes + reg (`gemma3_text`) | ML-multilingual-v2 **61.36**; eng-v2 68.46; Code-v1 78.68; MIEB-lite 64.64 (card, 2026-10-06) | ⚠️ text-only yes; full multimodal heavy |
| `google/embeddinggemma-300m` | 308M (106M active) | 768 | **yes** 128/256/512/768 | **2,048** | 100+ | **Gemma Terms** (not OSI) | **173 MB** (measured) | **327 MB** (measured) | yes + reg | ML-multilingual-v2 **61.15**; eng-v2 69.67; Code-v1 68.76; ML-retrieval-v2 62.49 | ✅ best-documented on-device choice |
| `microsoft/harrier-oss-v1-270m` | 268M | **640** | ? **[unverified]** | 32,768 | 40+ | **MIT** | ~145 MB (est) | ~280 MB (est) | via arch (`gemma3_text`) | ML-multilingual-v2 **66.55**, ML-retrieval-v2 **66.38** | ✅ **best score/size/ctx in the sub-300M class** |
| `microsoft/harrier-oss-v1-0.6b` | 596M | 1,024 | ? **[unverified]** | 32,768 | 40+ | **MIT** | ~320 MB (est) | ~610 MB (est) | via arch (`qwen3`) | ML-multilingual-v2 **69.01**, ML-retrieval-v2 **70.75** — beats Qwen3-Embedding-8B on retrieval | ✅ strong |
| `microsoft/harrier-oss-v1-27b` | 27.0B | 5,376 | ? | 131,072 | 40+ | MIT | ~13.5 GB | — | no | ML-multilingual-v2 **74.27** (#1), ML-retrieval-v2 **78.27** | ❌ server |
| `Qwen/Qwen3-Embedding-0.6B` | 596M | 1,024 | yes, 32→1024 | 32,768 | 100+ | **Apache-2.0** | **335 MB** (measured, 4bit-DWQ) | **633 MB** (measured) | yes + reg | ML-multilingual-v2 64.34; eng-v2 70.47; ML-retrieval-v2 64.65; BEIR 55.52; Code-v1 75.42 | ✅ |
| `Qwen/Qwen3-Embedding-4B` | 4.02B | 2,560 | yes | 40,960 | 100+ | Apache-2.0 | **2.26 GB** (measured) | — | yes | ML-multilingual-v2 69.45; eng-v2 74.61; Code-v1 80.07 | ⚠️ only if nothing else resident |
| `Qwen/Qwen3-Embedding-8B` | 7.57B | 4,096 | yes | 40,960 | 100+ | Apache-2.0 | **4.26 GB** (measured) | — | yes | ML-multilingual-v2 **70.58**; eng-v2 75.23; ML-retrieval-v2 70.88; BEIR 62.76; Code-v1 80.69 | ❌ server |
| `nomic-ai/nomic-embed-text-v1.5` | 137M | 768 | yes (down to 64) | 8,192 | English | Apache-2.0 | ~80 MB (est; sibling ModernBERT 4-bit measured **84 MB**) | ~140 MB | via arch (`nomic_bert`) | eng-v2 62.20; ML-multilingual-v2 44.10; ML-retrieval-v2 34.09 | ✅ tiny, weak multilingual |
| `nomic-ai/nomic-embed-text-v2-moe` | 475M total / 305M active (MoE, 8 experts) | 768 | yes | 512 | ~100 | Apache-2.0 | ~260 MB (est) | ~480 MB (est) | no | ML-multilingual-v2 57.64; eng-v2 63.64; ML-retrieval-v2 57.21 | ✅ but 512-token ctx is a real limitation |
| `BAAI/bge-m3` | 568M | 1,024 | no | 8,192 | 100+ | **MIT** | **320 MB** (measured) | ~600 MB | yes + reg | ML-multilingual-v1 retrieval 54.59; eng-v2 retr 55.44 → **stale by 2026** | ✅ legacy but still the standard hybrid baseline |
| `BAAI/bge-large-en-v1.5` | 335M | 1,024 | no | 512 | English | MIT | ~170 MB (est) | ~340 MB | yes + reg | eng-v2 65.89 / retr 55.44; ML-multilingual-v2 45.08 | ✅ superseded |
| `BAAI/bge-small-en-v1.5` | 33M | 384 | no | 512 | English | MIT | **18.9 MB** (measured) | ~38 MB | yes + reg | eng-v2 64.30 / retr 53.86; ML-multilingual-v2 43.76 | ✅ ultra-light |
| `Alibaba-NLP/gte-multilingual-base` | 305M | 768 | no | 8,192 | 70+ | Apache-2.0 | ~155 MB (est) | ~310 MB | no | eng-v2 retr 50.87; ML-multilingual-v1 no mean | ✅ dated |
| `Alibaba-NLP/gte-Qwen2-1.5B-instruct` | 1.54B | 8,960 (MRL) | yes | 131,072 | multilingual | Apache-2.0 | ~800 MB (est) | — | no | ML-multilingual-v1 59.45; BEIR 58.29 | ⚠️ |
| `Alibaba-NLP/gte-Qwen2-7B-instruct` | 7.07B | 3,584 | yes | 131,072 | multilingual | Apache-2.0 | ~3.6 GB (est) | — | no | ML-multilingual-v1 62.51; BEIR 58.86 | ❌ |
| `intfloat/multilingual-e5-small` | 118M | 384 | no | 512 | 100+ | MIT | ~60 MB (est; MLX fp16 **235 MB**) | ~120 MB | yes + reg | eng-v2 59.69; ML-multilingual-v2 no mean | ✅ |
| `intfloat/multilingual-e5-large` | 560M | 1,024 | no | 512 | 100+ | MIT | ~290 MB (est) | ~570 MB | yes | eng-v2 retr 51.53 | ✅ dated |
| `intfloat/multilingual-e5-large-instruct` | 560M | 1,024 | no | 514 | 100+ | MIT | ~290 MB (est) | ~570 MB | no | ML-multilingual-v1 **63.22**; ML-multilingual-v2 63.22 / retr 57.11 | ✅ |
| `intfloat/e5-large-v2` | 335M | 1,024 | no | 514 | English | MIT | ~170 MB (est) | ~340 MB | no | eng-v2 62.79 | ✅ dated |
| `jinaai/jina-embeddings-v3` | 572M | 1,024 | yes 32→1024 | 8,192 | 100+ | **CC-BY-NC-4.0** ⛔ | ~300 MB (est) | ~600 MB | no | ML-multilingual-v2 58.37; eng-v2 retr 54.29 | ⛔ NC license |
| `jinaai/jina-embeddings-v5-text-nano` | 239M (212M) | 768 | yes 32/64/128/256/512/768 | 32K (card) / 8,192 (MTEB meta) | multilingual | **CC-BY-NC-4.0** ⛔ | ~130 MB (est; MLX fp16 **478 MB**) | ~250 MB | **yes (vendor MLX)** | eng-v2 71.11 / retr 58.80; ML-multilingual-v2 65.52 / retr 63.26 | ⛔ NC license |
| `jinaai/jina-embeddings-v5-text-small` | 596M | 1,024 | yes | 32,768 | multilingual | **CC-BY-NC-4.0** ⛔ | ~320 MB (est) | — | **yes (vendor MLX)** | eng-v2 retr 60.07; ML-retrieval-v2 64.88 | ⛔ NC license |
| `jinaai/jina-embeddings-v4` | 3.94B (Qwen2.5-VL-3B base) | 2,048 | yes 128→2048 | 32,768 | 30+ | **Qwen Research License** ⛔ (non-commercial) | ~2.2 GB (est) | — | no | ML-retrieval-v2 not reported; MIEB-lite no score | ❌ + ⛔ |
| `dunzhang/stella_en_1.5B_v5` | 1.54B | 8,960 | yes (MRL) | 131,072 | English | MIT | ~800 MB (est) | — | no | eng-v2 69.43 / retr 52.42; BEIR 59.31 | ⚠️ |
| `dunzhang/stella_en_400M_v5` | 435M | 4,096 | yes (MRL) | 8,192 | English | MIT | ~225 MB (est) | ~450 MB | no | eng-v2 69.39 / retr 52.73; BEIR 57.86 | ✅ English-only |
| `mixedbread-ai/mxbai-embed-large-v1` | 335M | 1,024 | yes 512/256/128/64 | 512 | English | Apache-2.0 | ~180 MB (est; MLX fp16 **670 MB**) | ~340 MB | yes + reg | eng-v2 66.26 / retr 55.40; ML-multilingual-v2 45.91 | ✅ dated |
| `Snowflake/snowflake-arctic-embed-l-v2.0` | 568M | 1,024 | yes (256) | 8,192 | multilingual | Apache-2.0 | **320 MB** (measured) | ~600 MB | yes | ML-multilingual-v2 57.03 / retr 58.36; eng-v2 retr 58.56; BEIR 55.22 | ✅ |
| `Snowflake/snowflake-arctic-embed-m-v2.0` | 305M | 768 | yes (256) | 8,192 | multilingual | Apache-2.0 | ~160 MB (est) | ~310 MB | no | eng-v2 retr **58.41**; BEIR 55.49 | ✅ |
| `Snowflake/snowflake-arctic-embed-s` | 33M | 384 | no | 512 | English | Apache-2.0 | ~20 MB (est) | ~38 MB | no | eng-v2 61.59 / retr 54.85 | ✅ tiny |
| `ibm-granite/granite-embedding-311m-multilingual-r2` | 312M | 768 | **yes** | **32,768** | 200+ (52 trained) | Apache-2.0 | ~160 MB (est) | ~320 MB | no | ML-multilingual-v2 mean 55.96 but **ML-retrieval-v2 65.21**; Code-v1 63.84 | ✅ retrieval-tuned |
| `ibm-granite/granite-embedding-97m-multilingual-r2` | 97M | 384 | yes | 32,768 | 200+ | Apache-2.0 | ~50 MB (est) | ~100 MB | no | ML-retrieval-v2 **60.32**; Code-v1 60.43 | ✅ |
| `KaLM-Embedding/KaLM-embedding-multilingual-mini-instruct-v2.5` | ~494M | 896 | yes 64→896 | ? | multilingual | Apache-2.0 | ~260 MB (est) | — | no | not on MTEB leaderboard as of 2026-10-12 | ✅ |
| `LiquidAI/LFM2.5-Embedding-350M` | 350M | ? | ? | ? | 11 langs | **LFM Open License 1.0** ("other") ⚠️ | **200 MB** (measured, MLX) | ~360 MB | yes (community MLX) | not on MTEB leaderboard | ✅ check license terms |
| `Qwen/Qwen3-Embedding-0.6B`-class rivals: `Octen/Octen-Embedding-8B`, `codefuse-ai/F2LLM-v2-*`, `nvidia/llama-embed-nemotron-8b`, `tencent/KaLM-Embedding-Gemma3-12B-2511`, `ai-sage/Giga-Embeddings-instruct-10B-A1.8B` | 1.7B–27B | 2,048–5,376 | mixed | up to 131K | multilingual | mostly open | ≥800 MB | — | partial | all in the top-20 of ML-multilingual-v2 | ❌ server-tier |

**Reading the table.** Two facts dominate the phone decision:

1. **The sub-300M class jumped two generations in 2026.** `microsoft/harrier-oss-v1-270m` scores **66.55** (ML-multilingual-v2 mean) / **66.38** (retrieval) at 268M parameters — *above* `Qwen/Qwen3-Embedding-0.6B` (64.34 / 64.65) and *far* above `google/embeddinggemma-300m` (61.15 / 62.49), which was the state of the art for this size in Sept 2025. It is **MIT**-licensed with **32,768-token** context. That is the single most important line in this report.
2. **Scale still buys something, but less than you'd think.** Going 0.6B → 8B (13× the parameters, 13× the RAM) buys **+6.2** ML-multilingual-v2 mean and **+6.2** retrieval points for Qwen3. Going 270M → 27B (100× the parameters) buys **+7.7** mean / **+11.9** retrieval. Meanwhile `microsoft/harrier-oss-v1-0.6b` (596M) *beats* Qwen3-Embedding-8B on multilingual retrieval (70.75 vs 70.88 — effectively tied) at 1/13 the size.

**Licenses that matter commercially.** Most of the ecosystem is permissive (Apache-2.0 / MIT), but three families are not:

- **Jina v3, v4, v5, jina-colbert-v2, jina-reranker-v2/v3 — CC-BY-NC-4.0 or Qwen Research License.** The v3 card says outright: *"the model is licensed under CC BY-NC 4.0. For commercial usage inquiries, feel free to contact us."* The v4 card corrects its own license to the **Qwen Research License** (non-commercial). **These are research-only.** Their benchmark numbers are excellent and their MLX support is first-party, which makes them a trap for a shipping app. ⛔
- **EmbeddingGemma 1 (`license: gemma`).** Commercial use *is* permitted, but the Gemma Terms of Use impose real obligations: you must pass the Section 3.2 use restrictions through to downstream users, ship a copy of the agreement, include a NOTICE file with a specific string, and mark modified files. Google also reserves the right to restrict usage remotely, and may terminate for breach. This is workable but is *not* the same as Apache-2.0.
- **EmbeddingGemma 2 is Apache-2.0** — Google moved to a clean permissive license for the second generation. Also note `LiquidAI/LFM2.5-Embedding-350M` ships under the LFM Open License ("other"), not a standard OSI license.

Everything else in the table (Qwen3, BGE, Nomic, GTE, E5, Stella, MXBAI, Arctic, Granite, Harrier, MiniLM, ColBERT-Zero/LateOn) is Apache-2.0 or MIT.

### 1.2 Cross-encoder rerankers

Rerankers are a *different* compute shape: one forward pass **per (query, document) pair**, so cost scales with `k × doc_len`, not with corpus size. They are used to reorder a short candidate list (typically 20–200) produced by a cheap first stage.

| Model | Params | Max ctx | License | ≈4-bit | MLX | Quality evidence |
|---|---|---|---|---|---|---|
| `BAAI/bge-reranker-v2-m3` | 568M | 8,194 | Apache-2.0 | ~300 MB (est) | **reg** in MLX Swift (`EmbedderRegistry.bge_reranker_v2_m3`) | MTEB-R 57.03; CMTEB-R 72.16; MMTEB-R 58.36 (Qwen3 card, 2025-06) |
| `Qwen/Qwen3-Reranker-0.6B` | 596M | 40,960 | Apache-2.0 | **335 MB** (measured) | **yes** (`mlx-community/Qwen3-Reranker-0.6B-4bit`) | MTEB-R **65.80**; MMTEB-R 66.36; MLDR 67.28; MTEB-Code 73.42 |
| `Qwen/Qwen3-Reranker-4B` | 4.02B | 40,960 | Apache-2.0 | ~2.3 GB | mxfp8 only | MTEB-R **69.76**; FollowIR 14.84 (best) |
| `Qwen/Qwen3-Reranker-8B` | 7.57B | 40,960 | Apache-2.0 | ~4.3 GB | mxfp8 only | MTEB-R 69.02; CMTEB-R 77.45 |
| `jinaai/jina-reranker-v2-base-multilingual` | 278M | 1,026 | **CC-BY-NC-4.0** ⛔ | ~140 MB (est) | no | MTEB-R 58.22 |
| `jinaai/jina-reranker-v3` / `v3.5` | 597M | 131,072 | **CC-BY-NC-4.0** ⛔ | ~320 MB (est) | yes (`jina-reranker-v3-4bit-mxfp4`) | v3: **BEIR nDCG@10 61.94** with a listwise "last-but-late-interaction" design; 64 docs per pass |
| `mixedbread-ai/mxbai-rerank-large-v2` | 1.54B | 32,768 | Apache-2.0 | ~800 MB (est) | yes (`mxbai-rerank-large-v2`) | — |
| `mixedbread-ai/mxbai-rerank-base-v1` | 184M | 512 | Apache-2.0 | ~100 MB (est) | no | — |
| `cross-encoder/ms-marco-MiniLM-L6-v2` | 23M | 512 | Apache-2.0 | ~13 MB (est) | no | classic, weak by 2026 standards |
| `cross-encoder/ettin-reranker-{17m,32m,68m,150m,400m,1b}-v1` | 17M–1.03B | 7,999 | Apache-2.0 | 8 MB–500 MB | no | new (2026-05-15); sizes suggest a ModernBERT-encoder family |
| `zeroentropy/zerank-1-small`, `zerank-2` | 1.72B / 4.02B | 40,960 | **CC-BY-NC-4.0** ⛔ | 3.3–7.7 GB | no | server-tier |
| `lightonai/LightOn-rerank-{PW,LW}-{0.8B,2B,4B}` | 853M–4.5B | 16,384 | Apache-2.0 | 1.6–8.7 GB | no | **multimodal** (image+text) rerankers, 2026-07-08 |
| `nvidia/llama-nemotron-rerank-1b-v2` | 1.24B | 4,096 | OpenMDW-1.1 | ~600 MB (est) | no | — |

**The phone-realistic rerankers are `bge-reranker-v2-m3` (already wired into MLX Swift) and `Qwen3-Reranker-0.6B` (335 MB at 4-bit, Apache-2.0, and the strongest sub-1B reranker by a wide margin: +8.8 MTEB-R over bge-reranker-v2-m3 at the same parameter count).**

### 1.3 Late interaction (ColBERT-style) — a distinct technique, not a dense variant

Late interaction keeps **one vector per token**, then scores with MaxSim (for each query token, take its best-matching document token; sum). It sits between dense and cross-encoder on both quality and cost.

| Model | Params | Per-token dim | Storage per 256-token doc | License | Quality |
|---|---|---|---|---|---|
| `colbert-ir/colbertv2.0` | 110M | 128 | ~32 KB fp16 | MIT | BEIR-classic baseline; 180-token ctx |
| `lightonai/GTE-ModernColBERT-v1` | 149M | 128 | ~32 KB fp16 | Apache-2.0 | **BEIR 54.75** (2025-04-30) |
| `lightonai/ColBERT-Zero` | 149M | 128 | ~32 KB fp16 | Apache-2.0 | **BEIR 55.39** (2026-02-19) — *ties Qwen3-Embedding-0.6B's 55.52 on BEIR at ¼ the parameters* |
| `lightonai/LateOn`, `LateOn-Code` | 149M / 307M | 128 | ~32 KB | Apache-2.0 | code-focused (2026-02) |
| `lightonai/LateOn-Code-edge` | **17M** | **48** | ~6 KB | Apache-2.0 | edge-targeted |
| `lightonai/mLateOn` | 307M | 128 | ~32 KB | Apache-2.0 | multilingual (2026-07-30) |
| `jinaai/jina-colbert-v2` | 559M | — | large | **CC-BY-NC-4.0** ⛔ | — |
| `nomic-ai/colnomic-embed-multimodal-{3b,7b}` | 3.0B / 7.0B | 128 | very large | Apache-2.0 | image+text |

**Verdict for this app: do not build late interaction yet.** The storage multiple is the killer — a 256-token chunk becomes 256 × 128 dims instead of 1 × 768, i.e. **~40× the bytes** (roughly 32 KB vs 0.8 KB per chunk in fp16), and scoring is a MaxSim loop rather than a single dot product. You buy a few nDCG points over a good dense model plus strong out-of-vocabulary robustness. There is **no MLX Swift late-interaction path** (`MLXEmbedders` has no MaxSim/ColBERT model class), so you would be writing and maintaining a custom Metal kernel path for a marginal gain.

### 1.4 Multimodal (text ↔ image / audio / video)

| Model | Params | Dims | Modalities | License | ≈4-bit | MLX | Benchmarks |
|---|---|---|---|---|---|---|---|
| `google/embeddinggemma-2` | 740M | 768 (MRL→128) | text, image, video, audio | **Apache-2.0** | 1.10 GB (MLX) / **485 MB (LiteRT)** / **165 MB text-only** | yes (`mlx-community/embeddinggemma-2-*`) | MIEB-lite **64.64**; MMEB-v2 img 57.28, visdoc 67.84, video 50.67; MSEB-retrieval 69.54; MAEB 49.39 |
| `jinaai/jina-embeddings-v5-omni-small` | 1.63B | 1,024 | text, image, audio, video | **CC-BY-NC-4.0** ⛔ | ~800 MB (est) | vendor MLX | MIEB-lite 61.07; eng-v2 71.78 |
| `jinaai/jina-embeddings-v5-omni-nano` | 986M | 768 | text, image, audio, video | **CC-BY-NC-4.0** ⛔ | ~500 MB (est) | vendor MLX | MIEB-lite 49.38 |
| `LCO-Embedding/LCO-Embedding-Omni-7B` | 8.9B | 3,584 | multimodal | — | ~4.5 GB | no | MIEB-lite **68.76** (best) |
| `Haon-Chen/e5-omni-3B` / `7B` | 4.7B / 8.9B | 2,048 / 3,584 | text, image, audio, video | **MIT** | ~2.4 / 4.5 GB | no | MIEB-lite 57.11 / 65.21 |
| `Qwen/Qwen3-VL-Embedding-2B` | 2B | — | text, image | Apache-2.0 | **1.78 GB** (measured MLX) | yes | — |
| `nomic-ai/nomic-embed-vision-v1.5` | 93M | 768 | text, image | Apache-2.0 | ~50 MB (est) | no | MIEB-lite **36.36** — weak |
| `mongodb/voyage-multimodal-3` | API | 1,024 | text, image | proprietary | n/a | no | MIEB-lite 59.7 |
| `nvidia/omni-embed-nemotron-3b` | 4.7B | 2,048 | text, image, audio, video | NVIDIA license | ~2.4 GB | no | — |

**Apple's zero-download alternatives — and exactly where they stop working:**

| API | Availability | What it gives you | The catch |
|---|---|---|---|
| `NLEmbedding` (`wordEmbedding(for:)`, `sentenceEmbedding(for:)`) | iOS 13+ | `vector(for:)` → `[Double]`, `neighbors(for:)`, `distance(between:and:)`, plus a compiled on-disk custom embedding you can build with `writeEmbeddingForDictionary:…` | It is a **vocabulary lookup**, not an encoder. Strings outside the vocabulary have no vector. Sentence embeddings are built from word vectors, so quality is far below a transformer. Apple's own docs say a single instance **is not safe for concurrent use** and can crash the app if queried from multiple threads — you must serialize access. Dimension is undocumented and varies by language/revision; read `dimension`. **[unverified]** exact dims |
| `NLContextualEmbedding` | iOS 17+ | Real transformer contextual embeddings, `dimension`, `maximumSequenceLength`, per-language models | Returns **per-token** vectors (`NLContextualEmbeddingResult`), not a pooled sentence vector — you must pool yourself. Requires an **asset download** (`requestAssets`) and `load()`/`unload()`. Critically, Apple's own docs redirect semantic-similarity users back to `NLEmbedding`: *"For semantic similarity tasks, consider using NLEmbedding."* It is positioned for classification features (`MLTextClassifier.FeatureExtractorType.bertEmbedding`), not retrieval. |
| `VNGenerateImageFeaturePrintRequest` + `VNFeaturePrintObservation.computeDistance(_:to:)` | iOS 13+ | Free image→image similarity from a Vision feature print; no model download; runs on ANE | **Image→image only.** There is no text side, so no text→image search is possible. Distances are not calibrated across model revisions, and the revision constant (`…Revision1`) is part of the identity. Practical thresholds from a production photo-dedup package: distance ≤ **0.08** ≈ duplicate, ≤ **0.40** ≈ similar, 4.0 ≈ 0 % similar. Element count/type are exposed via `elementCount` / `elementType` rather than documented. **[unverified]** exact dimensionality (commonly reported as 2048 fp32 for rev 1–2) |

**Bottom line for multimodal:** for image *dedup* and near-duplicate detection in `attachments/`, use `VNGenerateImageFeaturePrintRequest` — it is free, on-device, no download, and good enough. For **text→image** search you must load a joint text-image embedder, and the only commercially-licensed sub-1 GB option today is EmbeddingGemma 2's 440M text+vision configuration (or the full 740M model at 485 MB in LiteRT / 1.10 GB in MLX). Everything else competitive is CC-BY-NC or multi-GB.

---

## 2. How embeddings are actually used

Each pattern below is a named, shipped pattern with a one-line mechanism. "First stage" = the cheap retrieval pass; "second stage" = the expensive re-ordering pass.

### 2.1 Retrieval

| Pattern | Mechanism | Notes / evidence |
|---|---|---|
| **Dense RAG over documents** | Embed query and chunks into the same space; return top-k by cosine; paste into the prompt. | The baseline everything else is measured against. Quality is dominated by chunking and by the *first stage's* recall, not by the generator. |
| **Hybrid BM25 + dense (lexical + semantic)** | Run a lexical scorer (BM25/`FTS5`) and a dense scorer in parallel, fuse the two ranked lists (RRF is the usual choice: `score = Σ 1/(60 + rank)`), then return the fused top-k. | **The single highest-ROI retrieval change on small models.** BEIR's own finding is that *"BM25 is a robust baseline"* and that dense models "often underperform other approaches" zero-shot ([arXiv:2104.08663](https://arxiv.org/abs/2104.08663)). MTEB ships hybrid baselines as first-class leaderboard entries (`mteb/baseline-hybrid-rrf-baseline-bm25s-multilingual-e5-small`) precisely because this is the standard comparison. Hybrid also fixes the classic dense failure mode: exact identifiers, error codes, file names, proper nouns. |
| **Chunking strategy** | Split on structure (headings, function boundaries, paragraph breaks) to ~200–500 tokens with ~10–20 % overlap; embed each chunk; store the parent doc id so you can expand to a wider window at generation time. | Chunks must be short enough that the semantics aren't over-compressed, but embedded independently they **lose surrounding context**. *Late chunking* ([arXiv:2409.04701](https://arxiv.org/abs/2409.04701)) fixes this: embed the **whole document** with a long-context encoder first, then mean-pool each chunk's token span — the chunk vectors then carry full-document context. This requires a long-context embedder, which is exactly why the 8K/32K-context small models in §1 matter. For an app whose "documents" are memory notes and tool outputs, structure-aware chunking plus a parent pointer beats clever splitting. |
| **Reranking stage** | Take top-N (20–200) from the first stage; score each `(query, chunk)` pair with a cross-encoder; return the reordered top-k. | Concrete gain, same-family: Qwen3-Embedding-0.6B retrieval on MTEB-R is **61.82**; reranking its top-100 with Qwen3-Reranker-0.6B gives **65.80** (+4.0), and with the 4B reranker **69.76** (+7.9) — i.e. *a 0.6B embedder + 4B reranker reaches what the 8B embedder reaches alone (70.88 on a different suite)*. Cost is `N` forward passes, not a corpus scan, so it is cheap to add and easy to cap. |
| **Query expansion / HyDE** | Have the LLM draft a hypothetical answer, embed *that* instead of the raw question, and retrieve with it. | Helps short, underspecified queries (a chat app's most common query shape). Costs one generation. |
| **Parent-document / small-to-big retrieval** | Index small chunks for matching, return the enclosing large chunk (or the whole file) to the model. | Decouples *match granularity* from *generation granularity*. Directly applicable to this app: match a memory bullet, return the whole memory file. |
| **MMR / diversity re-ranking** | After top-k, greedily pick results that are both relevant and dissimilar to already-picked ones. | Prevents returning five near-identical chunks from one document. Needs only the vectors you already have. |

### 2.2 Memory

| Pattern | Mechanism | Notes |
|---|---|---|
| **Episodic recall** | Embed each memory entry; retrieve by cosine to the current turn instead of keyword/fuzzy match. | This is the direct upgrade to a `memory_get` keyword search. Keyword search fails on paraphrase ("that restaurant in Kyoto" vs "the izakaya we found near the river"); dense recall does not. Keep the keyword path as the lexical half of a hybrid. |
| **Deduplication / consolidation of near-identical memories** | Compute pairwise cosine among recent entries; anything above a threshold (empirically ~0.90–0.95 for same-encoder sentence embeddings **[unverified]** — calibrate on your own data) is a merge candidate; ask the LLM to merge rather than append. | Prevents the classic failure of long-lived memory stores: 40 near-duplicate entries about the same preference. This is a *cheap* feature — it needs the vectors you already computed for recall, no extra model. |
| **Contradiction / supersession detection** | Very high similarity *plus* a semantic diff → flag as "this supersedes that" rather than "this duplicates that". | Cosine alone can't tell "I use an iPhone" from "I use an Android"; you need the LLM to adjudicate. Embeddings do the candidate selection, the LLM does the decision. |
| **Decay by similarity** | Rank recall by `similarity × recency_weight` (exponential decay on `last_accessed_at`), or drop entries whose nearest neighbour is above a merge threshold. | Turns a flat memory file into a living one. Requires storing `created_at` / `last_accessed_at` / `access_count` alongside the vector. |
| **Importance scoring** | At write time, embed the candidate memory and compare against the centroid of existing memories; high novelty → high importance. | A free, unsupervised importance signal, useful for deciding what survives summarization. |
| **Cross-session identity** | Cluster all session vectors; sessions in the same cluster are the same project/topic. | Powers "continue where we left off" without any explicit tagging. |
| **Session summaries as retrieval keys** | Embed a one-paragraph summary of each past session; retrieve the top-3 sessions for the current turn and inject them as context. | Cheaper than embedding every turn, and gives the chat model a coherent unit rather than a fragment. |

### 2.3 Routing / classification

| Pattern | Mechanism | Notes |
|---|---|---|
| **Intent routing to tools** | Embed a set of example utterances per intent; at runtime embed the user turn and take the nearest intent. | Deterministic, ~1 ms, no generation. Google explicitly lists this as an EmbeddingGemma use case: *"Classify user queries to relevant function calls to help mobile agent understanding."* |
| **Tool / skill selection when there are many schemas** | Embed each tool's name+description (and each SKILL.md's front-matter description); retrieve the top-5 most relevant, and put **only those** schemas in the prompt. | The fix for context bloat when MCP servers expose 50–200 tools. Directly relevant here: this app has MCP servers plus a `skills/` folder, and both grow unboundedly. Embedding the tool descriptions turns "which 5 of 120 tools do I show the model" into a vector lookup. Also makes tool selection robust to phrasing the schema author never anticipated. |
| **Topic clustering of sessions / offloads** | k-means or agglomerative clustering over L2-normalized vectors; name each cluster with the LLM. | Gives an automatic folder taxonomy for `offloads/` and a topic view of chat history. |
| **Sentiment / urgency triage** | Either a linear probe on the embedding, or nearest-neighbour against labelled examples. | EmbeddingGemma's card lists `task: classification \| query: {content}` as a first-class symmetric prefix, i.e. the model is explicitly trained for this. |
| **Deduplicating incoming tool outputs** | Before writing a large `offloads/` artifact, check whether a near-identical one already exists. | Saves disk and keeps the workspace navigable. |
| **Spam / anomaly / drift detection** | Flag inputs far from the centroid of the known distribution. | Cheap guardrail for an autonomous agent loop. |

### 2.4 Code / workspace

| Pattern | Mechanism | Notes |
|---|---|---|
| **Semantic search over a repo or file tree** | Chunk by function/class, embed, hybrid search, rerank. | The 2026 code-retrieval numbers are strong even for small models: `google/embeddinggemma-300m` scores **68.76** on MTEB(Code, v1) and EmbeddingGemma 2 jumps to **78.68** (+9.92, Google's own framing); `Qwen3-Embedding-0.6B` scores 75.42; `microsoft/harrier-oss-v1-0.6b` should be in the same band **[unverified — not published]**. |
| **Finding similar files** | Embed whole files (or file headers); nearest neighbours of the open file. | "This looks like 3 other files you already wrote" — useful for a workspace of generated scripts. |
| **Symbol search** | Embed each symbol's name + docstring + signature; query with natural language ("the thing that retries uploads"). | Complements (does not replace) a real symbol index. |
| **Commit / change-summary search** | Embed commit messages and diffs. | For a file-workspace app, embedding a change log gives "when did I last touch this?" semantics. |
| **Error → fix retrieval** | Embed past error messages paired with the fix that worked. | A memory-of-failures store; high value for an agent that runs shell commands. |
| **Docs → code grounding** | Embed the user's own notes/READMEs so the agent can ground on project conventions. | Bridges `workspace/` and `memory/`. |

### 2.5 Multimodal

| Pattern | Mechanism | Notes |
|---|---|---|
| **CLIP-style text ↔ image search** | Joint text/image encoder; embed the text query and every image into one space; cosine. | Requires a joint model. On-device options and their real footprints are in §1.4. |
| **Image dedup / near-duplicate photos** | Perceptual or feature-print distance; cluster; keep a medoid. | **Use `VNGenerateImageFeaturePrintRequest` — free, no download, iOS 13+.** Thresholds in §1.4. |
| **Screenshot search** | OCR the screenshot (Vision), embed the extracted text with a *text* embedder, and index it alongside a feature print for visual similarity. | The pragmatic hybrid: you get text→screenshot search with a cheap text model, and image→image with Vision, without loading a multimodal encoder. This is the pattern I'd recommend first. |
| **Visual-document (chart/table/PDF page) retrieval** | Embed rendered page images with a visual-document model (ViDoRe family: jina-v4, ColPali-style). | Server-tier on-device today. `jina-embeddings-v4` is 3.94B and non-commercial. |
| **Audio / video moment retrieval** | Embed audio segments or video keyframes; query with text. | EmbeddingGemma 2 is the only permissively-licensed small model that does this (MAEB 49.39, MMEB-video 50.67), and it needs 300M params of audio encoder or 170M of vision on top of the 270M text backbone. |
| **Attachment similarity for the agent** | "Find other attachments like this one." | Same as image dedup, but exposed as a tool. |

**Limits of the Apple-native path, stated plainly:** `VNGenerateImageFeaturePrintRequest` gives you **image→image only**. There is no text tower, so "find the screenshot where I discussed the API key" is impossible with Vision alone — you need OCR + a text embedder, or a joint multimodal model. `NLEmbedding` is a fixed-vocabulary lookup, not an encoder, and is not thread-safe. `NLContextualEmbedding` returns per-token vectors and needs an asset download, and Apple itself steers semantic-similarity work back to `NLEmbedding`. Treat all three as *complements* to a real embedder, not substitutes.

### 2.6 Evaluation / diagnostics

| Pattern | Mechanism | Notes |
|---|---|---|
| **Embedding-space visualisation** | Project to 2D with UMAP/t-SNE and colour by source folder or label. | The fastest way to see that your chunks are clustered by *file format* rather than *topic* — a bug you otherwise only discover as bad retrieval. Google ships an interactive 3D demo of EmbeddingGemma for exactly this. |
| **Drift detection** | Track the centroid and pairwise-distance distribution of new embeddings over time; alert on shift. | Catches "the user's usage changed" and "the model silently changed" with the same instrument. |
| **Measuring retrieval recall@k** | Build a small labelled set (50–200 query→doc pairs), then compute recall@k and nDCG@10 for the current pipeline. | **Non-negotiable before swapping models.** MTEB tells you which model is likely better; only your own set tells you whether it is better *for your corpus*. A 50-query set takes an hour to build and prevents every bad model decision. |
| **Reranker lift measurement** | Compute recall@k before and after the rerank stage. | If reranking doesn't lift your metric, your first stage is already saturated at that k, or your reranker is misconfigured. |
| **Chunk-size sweep** | Re-index at 128/256/512/1024 tokens and plot recall@10. | The single most common source of accidental bad retrieval. Cheap to run once. |
| **Index-health checks** | Count orphaned vectors, vectors with `dim != expected`, vectors whose `model_version` is stale, and duplicate chunk hashes. | See §4.5 — every one of these is a silent failure mode. |
| **Latency / cost budget tracking** | p50/p95 for embed, search, rerank. | A brute-force scan that creeps from 8 ms to 80 ms is a product regression even though nothing "broke". |

---

## 3. Small-model quality reality check

### 3.1 What an MTEB gap between a 300M and a 7B embedder actually means

**First, a calibration warning that invalidates most comparisons you will read online.** MTEB has multiple incompatible suites and vendors mix them freely:

- `MTEB(Multilingual, v1)` and `MTEB(Multilingual, v2)` are different task sets. `google/embeddinggemma-300m` scores **61.15** on v2; `Qwen/Qwen3-Embedding-8B`'s famous "70.58" is on **v1** (its card says "No.1 in the MTEB multilingual leaderboard, as of June 5, 2025, score 70.58"). On the *same* suite the comparison is 61.15 vs 70.58 — but the v2 number for Qwen3-8B is also 70.58, so here they happen to coincide. Do not assume that in general.
- **The headline mean hides the retrieval sub-score, and the two can disagree violently.** `ibm-granite/granite-embedding-311m-multilingual-r2` has a *mean* of **55.96** on ML-multilingual-v2 — which looks terrible — but a *retrieval* sub-score of **65.21**, which beats `BAAI/bge-m3` (54.59) and `jina-embeddings-v3` (55.76) and sits close to `Qwen3-Embedding-0.6B` (64.65). A 9.3-point spread between the mean and the sub-score for a single model. **For a search/recall feature, always read the Retrieval column; the mean is dominated by classification and STS tasks you will never run.**

**Same-family scaling, measured (all from the MTEB leaderboard API, 2026-10-12):**

| Comparison | Params ratio | MTEB(eng, v2) mean | MTEB(eng, v2) **retrieval** | ML-multilingual-v2 mean | ML-multilingual-v2 **retrieval** |
|---|---|---|---|---|---|
| Qwen3-Embedding 0.6B → 4B | 6.7× | 70.47 → 74.61 (**+4.14**) | 61.83 → 68.46 (**+6.63**) | 64.34 → 69.45 (**+5.11**) | 64.65 → 69.60 (**+4.95**) |
| Qwen3-Embedding 0.6B → 8B | 12.7× | 70.47 → 75.23 (**+4.76**) | 61.83 → 69.44 (**+7.61**) | 64.34 → 70.58 (**+6.24**) | 64.65 → 70.88 (**+6.23**) |
| Qwen3-Embedding 4B → 8B | 1.9× | 74.61 → 75.23 (**+0.62**) | 68.46 → 69.44 (**+0.98**) | 69.45 → 70.58 (**+1.13**) | 69.60 → 70.88 (**+1.28**) |
| EmbeddingGemma-300m → Qwen3-Embedding-8B | 24.6× | 69.67 → 75.23 (**+5.56**) | 55.69 → 69.44 (**+13.75**) | 61.15 → 70.58 (**+9.43**) | 62.49 → 70.88 (**+8.39**) |
| **harrier-oss-v1-270m → Qwen3-Embedding-8B** | **28.2×** | n/a (not published) | n/a | 66.55 → 70.58 (**+4.03**) | 66.38 → 70.88 (**+4.50**) |
| **harrier-oss-v1-270m vs EmbeddingGemma-300m** | **0.87× (smaller!)** | n/a | n/a | 66.55 vs 61.15 (**+5.40**) | 66.38 vs 62.49 (**+3.89**) |

**How to convert that into recall@10.** MTEB's Retrieval task-type score is an average of nDCG@10 (with some recall@100 and MRR mixed in). nDCG@10 is more sensitive to *ordering within* the top 10 than recall@10 is, so as a heuristic the recall@10 delta is usually **equal to or smaller than** the nDCG@10 delta. Working rules of thumb for a fixed corpus and k=10 (heuristic — validate on your own set):

| Δ retrieval score (nDCG@10) | What it means in practice |
|---|---|
| **< 2 points** | Noise. Different tokenizer versions, different `transformers`/`MLX` builds, or run-to-run variance will move the number this much. Do not swap models for this. |
| **2–5 points** | Measurable on a 50–200 query labelled set (typically +2 to +5 recall@10 points), but users will rarely notice. Swap only if the new model is also cheaper or better licensed. |
| **5–10 points** | Clearly visible. On a 10-result list this is roughly "one more relevant hit, and it moved up". Worth a migration. |
| **> 10 points** | Changes what the feature can do. Retrieval stops being a toy. |

**The strategic conclusion.** The 28× parameter gap between `harrier-oss-v1-270m` and `Qwen3-Embedding-8B` is worth **+4.5** retrieval points on ML-multilingual-v2 — inside the "measurable but rarely user-visible" band. Meanwhile a **reranker buys you more than scaling the embedder does**: Qwen3-Embedding-0.6B + Qwen3-Reranker-0.6B goes from 61.82 → 65.80 MTEB-R (**+3.98**) for a one-off cost of 335 MB and one forward pass per candidate — and the 4B reranker reaches +7.94. **On a phone, the right move is a small embedder plus a cheap reranking stage, not a big embedder.** Also note the 4B → 8B step costs 1.9× the RAM for **+0.6 to +1.3** points: pure waste at this scale.

### 3.2 When Matryoshka truncation (768 → 256) costs little vs a lot

Matryoshka Representation Learning trains a vector so that its *prefix* is itself a usable embedding ([arXiv:2205.13147](https://arxiv.org/abs/2205.13147)). The MRL paper claims up to **14× smaller embeddings at the same accuracy** for ImageNet-1K classification and up to **14× real-world retrieval speed-ups**. Truncation is free at inference — no extra training, no extra compute — but you **must re-normalize after truncating** if you use dot-product or L2 search. (Cosine is scale-invariant and unaffected; a dot-product/L2 index built on un-normalized truncated vectors is silently wrong.)

**EmbeddingGemma 1 — full published truncation table (from the official model card):**

| Dim | Compression | MTEB Multilingual v2 | MTEB English v2 | MTEB Code v1 |
|---|---|---|---|---|
| 768 (full) | 1× | 61.15 | 69.67 | 68.76 |
| 512 | 1.5× | 60.71 (**−0.44**) | 69.18 (**−0.49**) | 68.48 (**−0.28**) |
| 256 | 3× | 59.68 (**−1.47**) | 68.37 (**−1.30**) | 66.74 (**−2.02**) |
| 128 | 6× | 58.23 (**−2.92**) | 66.66 (**−3.01**) | 62.96 (**−5.80**) |

**EmbeddingGemma 2 — full published truncation table (model card, 2026-10-06):**

| Dim | MTEB ML-v2 | MTEB eng-v2 | MTEB Code-v1 | MIEB-lite | **MMEB-v2** | MSEB-retr | MAEB |
|---|---|---|---|---|---|---|---|
| 768 | 61.36 | 68.46 | 78.68 | 64.64 | 59.01 | 69.54 | 49.39 |
| 512 | 61.17 (−0.19) | 68.41 (−0.05) | 77.24 (−1.44) | 64.32 (−0.32) | 58.38 (−0.63) | 69.18 | 49.21 |
| 256 | 60.41 (**−0.95**) | 67.78 (−0.68) | 76.18 (−2.50) | 63.13 (−1.51) | 56.24 (−2.77) | 66.76 | 48.91 |
| 128 | 57.89 (**−3.47**) | 65.68 (−2.78) | 71.41 (**−7.27**) | 59.06 (−5.58) | **45.65 (−13.36)** | 56.71 | 46.92 |

**Rules of thumb:**

- **768 → 512 is essentially free** (−0.2 to −0.6 text; the only real cost is −1.44 on code). Take it by default; it is a free 1.5× storage saving.
- **768 → 256 costs ~1.0–1.5 points on text** — inside the "measurable, rarely user-visible" band — but **2.0–2.8 on code** and ~2.8 on cross-modal tasks. **256 is the sweet spot for a text-memory workload; it is the wrong choice for a code-search workload.**
- **768 → 128 costs 3–3.5 points on text and 5.8–7.3 on code.** For a *text-only* memory index, 128 is defensible if you are storage-constrained. For anything cross-modal it collapses (MMEB −13.4). Google's own guidance: *"128d is best suited to text-only workloads."*
- **Truncation cost is model-dependent.** `jina-embeddings-v5-text-nano` is explicitly trained to be "robust under truncation and binary quantization", and `jina-embeddings-v4` claims truncation "to as low as 128 with minimal performance loss". Not every MRL model degrades as gracefully as EmbeddingGemma — **measure, don't assume**.
- Independent corroboration that smaller is often enough: *On the Dimensionality of Sentence Embeddings* ([arXiv:2310.15285](https://arxiv.org/abs/2310.15285)) finds "the optimal dimension of sentence embeddings is usually smaller than the default value."

### 3.3 Dimension vs index size vs search latency — the arithmetic

**Storage for a 100,000-document index.** `fp32 = 4 B/dim`, `int8 = 1 B/dim`, binary (1-bit) `= dim/8 B/vector`.

| Dims | **fp32** | **int8** | **binary (1-bit)** | fp32 index resident? |
|---|---|---|---|---|
| 128 | 51.2 MB | 12.8 MB | 1.6 MB | trivially |
| **256** | **102.4 MB** | **25.6 MB** | 3.2 MB | yes |
| 384 | 153.6 MB | 38.4 MB | 4.8 MB | yes |
| 512 | 204.8 MB | 51.2 MB | 6.4 MB | yes |
| **768** | **307.2 MB** | **76.8 MB** | 9.6 MB | yes, comfortably |
| 1,024 | 409.6 MB | 102.4 MB | 12.8 MB | yes |
| **1,536** | **614.4 MB** | **153.6 MB** | 19.2 MB | tight on an 8 GB device |
| 2,048 | 819.2 MB | 204.8 MB | 25.6 MB | no (8 GB) / tight (12 GB) |
| 4,096 | 1,638.4 MB | 409.6 MB | 51.2 MB | no |

*(100,000 × 768 × 4 B = 307,200,000 B = 307.2 MB; 100,000 × 1536 × 4 B = 614.4 MB; 100,000 × 4096 × 4 B = 1.638 GB. All arithmetic, not measured.)*

**Compute and memory traffic per query.** A brute-force scan does `N × d` multiply-accumulates = `2 × N × d` FLOPs, and streams `N × d × bytes_per_dim` bytes from RAM. For N = 100,000:

| Dims | MACs/query | FLOPs/query | Bytes streamed (fp32) | Bytes streamed (int8) |
|---|---|---|---|---|
| 256 | 25.6 M | 51.2 MFLOP | 102.4 MB | 25.6 MB |
| 768 | 76.8 M | 153.6 MFLOP | 307.2 MB | 76.8 MB |
| 1,536 | 153.6 M | 307.2 MFLOP | 614.4 MB | 153.6 MB |

**Why this is bandwidth-bound, not FLOP-bound.** On an A19 the memory subsystem delivers **68.2 GB/s** (8 GB LPDDR5X-8533); on an A19 Pro, **~75.8–76.8 GB/s** (12 GB LPDDR5X-9600) — Apple's own published figures are absent, so these come from the Wikipedia/NotebookCheck/Wccftech consensus **[unverified as first-party]**. Assume a realistic streaming efficiency of ~50–65 %, i.e. **35–50 GB/s**. Then a single 100k × 768 fp32 scan takes `307.2 MB ÷ 45 GB/s ≈ 6.8 ms`. The compute side at even a modest sustained 20 GFLOPS would take `153.6 MFLOP ÷ 20 GFLOPS ≈ 7.7 ms` — the same order. So the two costs are comparable, and either raising bandwidth efficiency (int8) or compute efficiency (batched GEMM) helps roughly linearly.

**Estimated single-query brute-force latency, 100,000 vectors [unverified — derived from the arithmetic above, not measured]:**

| Configuration | Est. latency | Comment |
|---|---|---|
| 256d fp32 | ~2–6 ms | trivial |
| 768d fp32 | ~5–15 ms | fine for interactive use |
| 768d int8 | ~2–5 ms | int8 halves memory traffic; dequantization cost is small with NEON `SDOT` |
| 1536d fp32 | ~12–30 ms | getting noticeable |
| 768d binary pre-filter + fp32 rescore of top-1,000 | **~0.5–1 ms** | 9.6 MB scan for the filter + 3 MB for the rescore; the coarse-to-fine pattern |

**Practical implementation note.** A naive `for doc in docs { vDSP_dotpr(query, 1, doc, 1, …) }` loop — which is literally what Apple's own reference implementation in `mlx-swift-examples/Tools/embedder-tool/VectorOperations.swift` does — leaves most of the machine idle because each call is a short, independent vector op with loop overhead. Replacing it with **one `cblas_sgemm` / `vDSP_mmul` call over the whole `[N × d]` matrix** lets Accelerate block the computation and route it through the AMX matrix coprocessor. Expect a **3–10× speed-up** for the same memory traffic **[unverified — standard Accelerate/AMX behaviour, not benchmarked on A19 here]**. This is a one-line change with the biggest single payoff in the whole search path.

**The scaling wall.** At 1,000,000 documents: 768d fp32 = **3.07 GB** (does not fit in an 8 GB A19 device's usable app memory at all, and leaves nothing for the chat model on 12 GB), 768d int8 = **768 MB** (fits, but is now a real budget line), 768d binary = 96 MB (fine). Latency scales linearly with N, so 1M × 768 fp32 is ~50–150 ms — past the interactive threshold. **That is where ANN becomes necessary, and not before.**

---

## 4. Engineering constraints on iOS specifically

### 4.1 Where the vectors should live

| Option | What it is | Pros | Cons | Verdict |
|---|---|---|---|---|
| **SQLite BLOB column + brute force in Swift** | Store `[Float]` (or int8) as a BLOB next to the chunk row; scan with Accelerate on query. | Zero new dependencies; transactional with the rest of the app state; trivial to version/migrate; survives app kill. | You write the scan loop. | ✅ **Start here.** |
| **SQLite + `sqlite-vec`** | C extension (Apache-2.0, v0.1.9, 2026-03-31, ~8.2k stars, "a vector search SQLite extension that runs anywhere") adding `vec0` virtual tables and float32/int8/binary vector types. | SQL-native `MATCH … ORDER BY distance`; KNN in the engine; handles int8/binary storage formats natively. | Still **0.1.x**; **no ANN index** (brute force underneath); must be **statically compiled into the app** — iOS cannot `dlopen` a dynamic library. | ✅ Good choice if you want SQL-native KNN and are willing to vendor a C extension. |
| **Brute force in pure Swift over an in-memory array** | Load all vectors, `cblas_sgemm` once per query. | Fastest possible for ≤100k; no disk I/O per query; ~5–15 ms at 100k×768 fp32. | RAM-resident (307 MB at 100k×768 fp32); cold-start load cost; every launch re-reads the blobs unless you keep them warm. | ✅ Fine for the 10k–100k range. |
| **`VecturaKit`** | Swift vector DB for iOS 18+, "local vector storage, indexing, and hybrid search with pluggable embedding providers". Has **hybrid vector + BM25** built in, pluggable embedders (`MLXEmbedder`, `NLContextualEmbedder`, `SwiftEmbedder`, OpenAI-compatible), persistent storage, auto dimension detection, and "automatic, full-memory, or indexed" memory strategies for "thousands to millions of documents". | Solves hybrid fusion, persistence and memory strategy for you; explicitly designed for this exact stack (MLX + iOS). | Third-party dependency; you inherit its schema and upgrade path; younger codebase. | ✅ **Strong candidate** — the hybrid search is the feature you'd otherwise hand-roll. |
| **`hnswlib` / `USearch` / FAISS** | Real ANN libraries (C++/Python). | Sub-linear search at millions of vectors. | Must be compiled in; HNSW graph build for 100k×768 is slow and memory-hungry on a phone; index files are ~1.5–2× the raw vector bytes; adds a tuning surface (`M`, `efConstruction`, `efSearch`) that can silently destroy recall. | ❌ Not yet. |
| **Core Spotlight** | Apple's on-device index. | Free, integrated with the OS. | **Not a vector store.** It indexes text/metadata for keyword and (limited) semantic matching, but you cannot supply your own embeddings or run a cosine query. | ❌ Not an embeddings backend. |

**Recommended shape:** one SQLite table `chunks(id, doc_id, text, content_hash, model_id, dim, dtype, prefix, generation, vec BLOB, created_at, last_seen_at)` + an in-memory `[Float]` matrix rebuilt at launch (or lazily), scanned with a single `cblas_sgemm`. Add `sqlite-vec` only if you want the KNN to live in SQL. Add `VecturaKit` if you want hybrid BM25 fusion for free.

### 4.2 What is realistic to brute-force on an A19

**The ops/sec reasoning.** Brute-force search is a memory-bandwidth problem, not a compute problem.

- A19: **68.2 GB/s** (8 GB LPDDR5X-8533). A19 Pro: **~75.8–76.8 GB/s** (12 GB LPDDR5X-9600). Realistic streaming efficiency ~50–65 % → **35–50 GB/s** effective. (Bandwidth figures are third-party consensus, not Apple-published **[unverified as first-party]**.)
- 100k × 768 fp32 = 307.2 MB streamed → `307.2e6 ÷ 45e9 ≈ 6.8 ms`.
- The compute side is `2 × N × d = 153.6 MFLOP`; at a sustained 20 GFLOPS that is 7.7 ms, at 100 GFLOPS (batched `sgemm` on the AMX coprocessor) it is 1.5 ms. So: **bandwidth-bound at the low end, compute-bound only if you use a naive per-vector loop.**
- **Conclusion: brute force to ~100k vectors at 768d fp32 is ~5–15 ms — well inside interactive.** With int8 storage it drops to ~2–5 ms. With a 1-bit pre-filter plus exact rescore of the top 1,000, it drops to ~0.5–1 ms and stays *exact*, not approximate.

**Resident-memory budget on an 8 GB A19 device.** A foreground iOS app on an 8 GB device gets a jetsam limit well below the physical RAM, and this app already carries a resident MLX chat model (a 3B model at 4-bit is ~1.8 GB). A 307 MB fp32 index is acceptable; 614 MB (1,536d) is questionable; 1.6 GB (4,096d) is not. **Dimension choice is a memory-budget decision, not a quality decision, once you are above ~256d.**

**One coexistence gotcha worth designing around.** If the embedder runs through **MLX/Metal**, it shares the Metal command queue and the unified-memory pool with the resident chat model. Interleaving an embed call mid-generation can produce a memory spike or a GPU stall. Two mitigations: (a) run the embedder through **Core ML / `MLTensor`** instead (`jkrukowski/swift-embeddings` does exactly this, supporting BERT / ModernBERT / NomicBERT / RoBERTa / XLM-RoBERTa / Qwen3) so it lands on the **Neural Engine**, a physically separate engine from the GPU — better coexistence *and* better power efficiency; or (b) keep the MLX embedder but serialize embed calls strictly outside generation. Note that MLX Swift *does* ship first-party embedder support (`ml-explore/mlx-swift-lm` → `Libraries/MLXEmbedders`: `EmbedderModelFactory`, `EmbedderModelContainer`, `EmbedderRegistry`, `Pooling` with `mean/cls/first/last/max/none`), with a registry that already includes `BAAI/bge-small-en-v1.5`, `BAAI/bge-m3`, `Snowflake/snowflake-arctic-embed-l`, `mixedbread-ai/mxbai-embed-large-v1`, `BAAI/bge-reranker-v2-m3`, `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`, and a `gemma3_text` architecture handler — so EmbeddingGemma-300m is a one-line load.

### 4.3 When an ANN index becomes necessary

Not at 10k, not at 100k. Trigger on **any** of:

| Trigger | Threshold | Why |
|---|---|---|
| Corpus size | > ~250k vectors at 768d fp32 (>750 MB) | RAM budget breaks before latency does |
| p95 query latency | > 50 ms | Interactive feel degrades |
| Cold-start / load time | > ~1 s to materialise the matrix | Users notice |
| Resident index budget | < 150 MB available | e.g. when a large chat model is resident |
| Query rate | many queries per turn (e.g. agent loop) | `queries × 7 ms` becomes seconds |

**Before reaching for HNSW, exhaust two cheaper options:** (1) **binary quantization pre-filter + exact rescore** — 1-bit vectors are 32× smaller than fp32, the Hamming scan is trivially fast with NEON `VCNT`/popcount, and rescoring the top 1,000 in fp32 restores exactness, so you get ANN-class speed with *no* recall loss and *no* index-build step; (2) **int8 storage** — 4× smaller, no build step, negligible quality loss for normalized embeddings. Only if you still can't hit the target should you take on HNSW's build cost, memory multiple, and recall-tuning surface.

### 4.4 Keeping embeddings consistent when documents change

**Identity.** Key every vector by `sha256(normalized_chunk_text)` plus the full embedding context, not by file path:

```
embedding_key = (content_hash, model_id, dim, dtype, pooling, task_prefix, generation)
```

Path-keyed caches break on rename; content-keyed caches survive it and make re-embedding idempotent.

**Change detection.** Keep a `documents(path, mtime, size, content_hash, last_seen_at)` table. On scan: if `(mtime, size)` unchanged, skip. If changed, re-read, re-chunk, diff the chunk hashes, embed **only the new hashes**, and mark the vanished hashes for deletion. This makes "edit one paragraph in a 5,000-word file" cost one embedding, not fifty.

**Model changes.** Never overwrite in place. Introduce an integer `generation`. On model swap: create generation N+1, backfill in the background (respecting thermals and battery), and flip a single `active_generation` row inside one transaction. Queries read only the active generation. If backfill is interrupted, you still have a fully consistent generation N. Never mix generations in one scoring pass — cross-generation cosine is meaningless.

**Atomic swap.** Because the flip is one row in one transaction, the switch is instantaneous and crash-safe. This is worth the extra storage during migration.

**Deletion.** Don't `DELETE` on file removal — set `last_seen_at` and run a vacuum after a grace period. Undo/restore then costs nothing.

### 4.5 Failure modes worth designing against

| # | Failure | Why it's dangerous | Mitigation |
|---|---|---|---|
| 1 | **Stale vectors after a model change** | Nothing errors. Results are simply worse, and you'll blame the retriever, the chunker, the LLM — everything but the actual cause. | `model_id` + `generation` on every row; a startup assertion that all active rows share one generation; a visible "reindex needed" state. |
| 2 | **Silent dimension mismatch** | Note that Apple's own reference code returns `0` on a length mismatch: `guard lhs.count == rhs.count else { return 0 }` (`VectorOperations.swift`). If you copy that idiom, a dimension bug produces a *plausible-looking* zero score rather than a crash — every query silently returns nothing. | **Hard-fail, never return 0.** Store `dim` per row and assert on read. Check dim at index-open time against the loaded model. |
| 3 | **Index bloat** | Orphaned vectors from deleted files, renamed files, re-chunking, and crashed migrations accumulate forever; they cost RAM and can outrank real results. | `last_seen_at` + periodic vacuum; report row count vs. document count in diagnostics; alert when the ratio drifts. |
| 4 | **Prefix / instruction drift** | EmbeddingGemma, Qwen3-Embedding, and harrier-oss are all **instruction-tuned with asymmetric prefixes**. harrier's own FAQ: *"Do I need to add instructions to the query? Yes, this is how the model is trained, otherwise you will see a performance degradation."* Embedding one side with the query prefix and the other with the document prefix silently wrecks retrieval, with no error. | Store the exact prefix string used on every vector. Make query-prefix and doc-prefix a single typed API so it's impossible to call the wrong one. |
| 5 | **Truncation without re-normalization** | MRL truncation is only valid if you re-normalize. With cosine it's harmless; with a dot-product or L2 index the ranking is silently wrong. | Always L2-normalize on write *and* on read. Store a `normalized` flag. |
| 6 | **Mixed quantization** | int8 vectors need a per-vector (or per-block) scale. Comparing int8 documents against an fp32 query without applying the scale changes the ranking while looking perfectly reasonable. | Store `dtype` and the scale with the vector; dequantize on read, or keep the query in the same dtype. |
| 7 | **NaN / Inf propagation** | One bad embedding poisons every subsequent comparison it participates in. | Sanitize on write (replace non-finite with 0) — Apple's own embedder tool does this explicitly, and it's cheap. |
| 8 | **Tokenizer / max-length truncation** | Context limits differ wildly: EmbeddingGemma-300m is **2,048 tokens**, nomic-embed-text-v2-moe is **512**, bge-small is **512**, while harrier-oss and Qwen3 are **32,768**. Exceeding the limit doesn't error — it silently drops the tail of the chunk. | Chunk *below* the model's limit; store the model's limit in the index metadata; warn when a chunk hits it. |
| 9 | **Thread-safety** | Apple states plainly that a single `NLEmbedding` instance "isn't safe for concurrent use… calling them on one instance from multiple threads or tasks at the same time can crash your app." SQLite needs a serialized queue; MLX containers are thread-safe by design (`EmbedderModelContainer.perform`). | Serialize access; one container per model; a single writer queue for the index. |
| 10 | **Model download & cold start** | A 173 MB (or 1.1 GB) first-use download, plus model load time on first embed after launch. | Gate the feature behind an explicit download with progress; warm the model on foreground if the feature is hot; never block the chat turn on a cold model load. |
| 11 | **Thermal throttling / battery** | Bulk-embedding a 5,000-file workspace on the ANE/GPU will throttle and drain battery. | Batch, run in the background, use `ProcessInfo.thermalState` and low-power-mode checks to pause/resume the backfill; keep the incremental path (one chunk at a time) as the steady state. |

---

## 5. Recommendation

### 5.1 What to build, ranked by (user value ÷ implementation cost)

**#1 — Hybrid semantic recall across `memory/` + `offloads/` + `workspace/`.**
*Mechanism:* embed every memory entry, every offload artifact's first ~500 tokens, and every workspace file chunk; fuse the existing keyword/fuzzy scorer with the dense scorer via RRF; return the top 20 to the **resident chat model** as a listwise reranker over the candidates (no extra model), then expand to the parent file for generation.
*Why first:* it is the only feature that makes the app's existing assets (a memory store, an offloads folder, a file workspace) *findable* rather than merely *stored*. It replaces the weakest current component — keyword/fuzzy `memory_get` — which fails on exactly the queries users make ("that thing I found last week about the API rate limit"). It reuses the app's whole existing stack: no new server, no network, no new UI surface.
*Implementation cost:* **low.** One SQLite table, one brute-force scan with `cblas_sgemm`, one RRF fusion with the existing keyword scorer, one model download.
*Model:* **`microsoft/harrier-oss-v1-270m`** (MIT, 268M params, 640 dims, **32,768-token context**, ~145 MB at 4-bit, ML-multilingual-v2 retrieval **66.38** — the best retrieval score of any sub-300M model on the board, and it beats EmbeddingGemma-300m by **+3.89** while being *smaller*). The 32K context is the decisive practical advantage: you can embed whole memory files and whole offloads without chunking, which removes the entire class of "the chunk lost its context" bugs.
*Fallback if the MLX integration is fiddly:* **`google/embeddinggemma-300m`** — 173 MB at 4-bit, **already in MLX Swift's `EmbedderRegistry`** (loaded via the `gemma3_text` architecture handler, one line), ML-multilingual-v2 retrieval 62.49. Zero integration risk, at the cost of 3.9 points and a 2,048-token limit that forces real chunking. Note the Gemma Terms pass-through obligations (§1.1).
*Avoid for #1:* `Qwen/Qwen3-Embedding-0.6B` (335 MB, retrieval 64.65) is *worse than harrier at more than twice the size* — it only makes sense if you need its 100+ language coverage beyond harrier's 40+.
*Truncation:* index at **256 dims**, not 768. EmbeddingGemma's own tables put 768→256 at only −1.0 to −1.5 points on text, and the index shrinks from 307 MB to 102 MB at 100k docs. Re-normalize after truncating.

**#2 — Memory dedup and consolidation at write time.**
*Mechanism:* before appending a new memory, embed it and compare against the centroid and the nearest existing entry; above ~0.90–0.95 cosine **[unverified threshold — calibrate on your data]**, hand the pair to the chat model to merge or supersede rather than append.
*Why second:* the app has a *persistent* memory system, which means its failure mode is slow corruption — 40 near-duplicate entries about the same preference crowding out the real ones and eating prompt budget. This is a data-quality feature that compounds: every week it runs, the memory gets better. It is also nearly free, because it needs **the same vectors #1 already computed** — no new model, no new index.
*Model:* the same one as #1. Zero marginal model cost.

**#3 — Tool and skill routing by embedding tool descriptions.**
*Mechanism:* embed each MCP tool's name+description and each `SKILL.md`'s description; at each turn retrieve the top-k (say 8) and put **only those** schemas in the prompt.
*Why third:* this app has two unbounded schema collections — MCP servers and a `skills/` folder — and finite context. Today, either everything is always injected (context bloat, worse instruction-following) or something is arbitrarily dropped (silent capability loss). Embedding-based routing converts "which tools do I show?" from a hard-coded decision into a 1 ms lookup, and Google explicitly ships this pattern ("Classify user queries to relevant function calls to help mobile agent understanding").
*Implementation cost:* **very low** — the index is tens to hundreds of entries, so it is a brute-force scan over a few hundred vectors (microseconds), and it reuses the #1 model and index infrastructure.
*Model:* the same one as #1. If you find the prefix requirement awkward for this symmetric task, use the symmetric prefix (`task: classification | query: …` on EmbeddingGemma; for harrier-oss use a one-sentence task instruction, which is what its card asks for).

### 5.2 What I would NOT build yet

| Don't build | Why not |
|---|---|
| **Text→image / text→audio / text→video search** | EmbeddingGemma 2 is the only permissively-licensed small option and it costs **1.10 GB at 4-bit in MLX** (485 MB in LiteRT, 165 MB text-only) — and MLX Swift's `MLXEmbedders` has **no multimodal embedding path** (its registry covers text architectures only: `bert`, `roberta`, `xlm-roberta`, `distilbert`, `nomic_bert`, `qwen3`, `lfm2`, `gemma3`, `gemma3_text`). Everything competitive is CC-BY-NC (Jina v5-omni) or multi-GB (LCO-Omni-7B, e5-omni-7B). Meanwhile **image→image** similarity is already free via `VNGenerateImageFeaturePrintRequest`. Revisit when a sub-300 MB text↔image MLX embedder exists. |
| **An ANN index (HNSW/FAISS/USearch)** | Brute force at 100k × 768 fp32 is ~5–15 ms — faster than the network round-trip a user can perceive. ANN adds a build step, a 1.5–2× index-size multiple, and a recall-tuning surface that can silently lose results. Use a **binary pre-filter + exact rescore** instead: 32× smaller, exact, no build. |
| **Late interaction / ColBERT** | ~40× the storage per chunk (one 128-d vector per token instead of one 768-d vector per chunk), MaxSim scoring instead of a dot product, and **no MLX Swift implementation**. You'd be writing a custom Metal kernel for a few nDCG points. |
| **A resident cross-encoder reranker** | Qwen3-Reranker-0.6B is 335 MB of extra resident model and `bge-reranker-v2-m3` ~300 MB, for a +4.0 MTEB-R lift. You can get most of that lift **for free** by asking the resident chat model to rerank the top 20 candidates in the same turn. Revisit only if measurements show the LLM rerank underperforming. |
| **Cloud embedding APIs** (OpenAI/Voyage/Cohere/Gemini) | Directly contradicts the app's premise. Every memory write and every query would leave the device, and the app would gain a network dependency, a per-call cost, and a rate limit on a feature that is supposed to work offline. |
| **Fine-tuning / domain adaptation** | Premature. You don't have a labelled retrieval eval set yet. Build the eval set first (§2.6) — it is an afternoon's work and it makes every subsequent model decision correct instead of vibes-based. |
| **A separate vector database service / embedding server** | Adds a process, a port, and a failure mode to an app that already has everything it needs in one SQLite file. |
| **Embedding the entire conversation history turn-by-turn** | Storage and compute grow without bound for marginal recall gain. Embed **session summaries** (one vector per session) instead, and expand to the full turns only when a session is retrieved. |

### 5.3 The three numbers that should drive the decision

1. **+3.89** — the ML-multilingual-v2 retrieval advantage of a **268M MIT** model (`harrier-oss-v1-270m`, 66.38) over the 2025 state of the art at that size (`embeddinggemma-300m`, 62.49). Small models caught up. You do not need a big embedder on a phone.
2. **+4.5** — what **28× more parameters** buys you (`harrier-oss-v1-270m` → `Qwen3-Embedding-8B` on multilingual retrieval). Below the user-visible threshold, at 28× the cost.
3. **+4.0** — what **one reranking pass** buys you (`Qwen3-Embedding-0.6B` 61.82 → 65.80 MTEB-R with `Qwen3-Reranker-0.6B`). Reranking beats scaling. On a phone, rerank with the model you already have resident.

---

## Appendix A — Primary sources

**Leaderboard & model metadata (all fetched 2026-10-12)**
- MTEB Leaderboard API (OpenAPI at `/openapi.json`): https://mteb-leaderboard-backend.hf.space/v1/benchmarks · https://mteb-leaderboard-backend.hf.space/v1/models
- MTEB Leaderboard UI: https://huggingface.co/spaces/mteb/leaderboard
- MTEB paper: https://arxiv.org/abs/2210.07316 · BEIR: https://arxiv.org/abs/2104.08663

**Models**
- EmbeddingGemma 2: https://huggingface.co/google/embeddinggemma-2 · card https://ai.google.dev/gemma/docs/embeddinggemma · launch blog https://blog.google/innovation-and-ai/technology/developers-tools/embeddinggemma-2/ · LiteRT builds https://huggingface.co/litert-community/embeddinggemma-2-740m-litert-lm
- EmbeddingGemma 1: https://huggingface.co/google/embeddinggemma-300m · blog https://developers.googleblog.com/en/introducing-embeddinggemma/ · paper https://arxiv.org/abs/2509.20354 · card https://ai.google.dev/gemma/docs/embeddinggemma/model_card
- Gemma Terms of Use: https://ai.google.dev/gemma/terms
- harrier-oss: https://huggingface.co/microsoft/harrier-oss-v1-270m · /microsoft/harrier-oss-v1-0.6b · /microsoft/harrier-oss-v1-27b
- Qwen3-Embedding / Reranker: https://huggingface.co/Qwen/Qwen3-Embedding-0.6B · paper https://arxiv.org/abs/2506.05176
- Jina v3/v4/v5: https://huggingface.co/jinaai/jina-embeddings-v3 · /jina-embeddings-v4 · /jina-embeddings-v5-text-nano · /jina-reranker-v3
- Others: https://huggingface.co/BAAI/bge-m3 · /BAAI/bge-reranker-v2-m3 · /nomic-ai/nomic-embed-text-v1.5 · /nomic-ai/nomic-embed-text-v2-moe · /Alibaba-NLP/gte-multilingual-base · /intfloat/multilingual-e5-large-instruct · /Snowflake/snowflake-arctic-embed-l-v2.0 · /mixedbread-ai/mxbai-embed-large-v1 · /dunzhang/stella_en_1.5B_v5 · /ibm-granite/granite-embedding-311m-multilingual-r2 · /sentence-transformers/all-MiniLM-L6-v2 · /lightonai/ColBERT-Zero · /colbert-ir/colbertv2.0 · /LiquidAI/LFM2.5-Embedding-350M · /KaLM-Embedding/KaLM-embedding-multilingual-mini-instruct-v2.5
- MLX conversions: https://huggingface.co/mlx-community/embeddinggemma-300m-4bit · /embeddinggemma-2-4bit · /Qwen3-Embedding-0.6B-4bit-DWQ · /bge-m3-mlx-4bit · /Qwen3-Reranker-0.6B-4bit · /snowflake-arctic-embed-l-v2.0-4bit · /all-MiniLM-L6-v2-4bit

**Papers cited**
- Matryoshka Representation Learning: https://arxiv.org/abs/2205.13147
- Late Chunking: https://arxiv.org/abs/2409.04701
- On the Dimensionality of Sentence Embeddings: https://arxiv.org/abs/2310.15285
- LoCo / M2-BERT (long-context retrieval): https://arxiv.org/abs/2402.07440
- arctic-embed: https://arxiv.org/abs/2405.05374

**iOS / Apple**
- `NLEmbedding`: https://developer.apple.com/documentation/naturallanguage/nlembedding
- `NLContextualEmbedding`: https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding
- `VNGenerateImageFeaturePrintRequest`: https://developer.apple.com/documentation/vision/vngenerateimagefeatureprintrequest
- `VNFeaturePrintObservation`: https://developer.apple.com/documentation/vision/vnfeatureprintobservation
- Production feature-print thresholds: https://github.com/nilkanthdesai76/swift-vision-photo-dedupe

**Swift / MLX stack**
- MLX Swift embedders (registry, pooling, reranker, architectures): https://github.com/ml-explore/mlx-swift-lm → `Libraries/MLXEmbedders/` (`ModelFactory.swift`, `EmbeddingModel.swift`, `Pooling.swift`, `Reranker.swift`) and `skills/mlx-swift-lm/references/embeddings.md`
- Apple's brute-force reference implementation (`vDSP_dotpr` + JSON index): https://github.com/ml-explore/mlx-swift-examples → `Tools/embedder-tool/` (`VectorOperations.swift`, `Indexing.swift`, `SearchCommand.swift`)
- `swift-embeddings` (Core ML / `MLTensor`, no MLX): https://github.com/jkrukowski/swift-embeddings
- `VecturaKit` (Swift vector DB, hybrid search, iOS 18+): https://github.com/rryam/VecturaKit · MLX provider https://github.com/rryam/VecturaMLXKit
- `sqlite-vec` (Apache-2.0, v0.1.9): https://github.com/asg017/sqlite-vec
- A19 / A19 Pro memory bandwidth: https://en.wikipedia.org/wiki/Apple_A19 · https://www.notebookcheck.net/Apple-A19-Pro-Processor-Benchmarks-and-Specs.1126974.0.html

## Appendix B — Unverified / estimated items

Every figure below is flagged in-line with **[unverified]** and is either an estimate derived from arithmetic or a claim I could not confirm from a primary source:

- All "≈4-bit / ≈8-bit" sizes marked *(est)* are `params × 0.5 B` / `params × 1 B`. Measured MLX file sizes are consistently **10–25 % larger** than that formula because some layers stay unquantized — prefer the *(measured)* numbers where given.
- All brute-force latency figures in §3.3 are **derived from the bandwidth arithmetic**, not benchmarked on an A19.
- The A19/A19 Pro bandwidth figures (68.2 / ~75.8–76.8 GB/s) are third-party consensus; Apple does not publish them.
- The 3–10× speed-up claim for `cblas_sgemm` over a per-vector `vDSP_dotpr` loop is standard Accelerate/AMX behaviour but is not benchmarked here.
- `microsoft/harrier-oss-v1-270m` and `-0.6b` loading through MLX Swift's existing `gemma3_text` / `qwen3` architecture handlers is **inferred from their `config.json`** (`model_type: gemma3_text` and `model_type: qwen3` respectively, both present in `ModelFactory.swift`'s registry) — **not tested**. Validate with a spike before committing.
- `microsoft/harrier-oss-v1-*` Matryoshka support is unknown; their model cards do not state it.
- `microsoft/harrier-oss-v1-*` MTEB(eng, v2) scores are not published (the leaderboard shows empty rows for all three sizes).
- `VNFeaturePrintObservation` element count / dimensionality is not documented by Apple; 2048 fp32 is the widely-reported figure.
- `NLEmbedding` vector dimensionality is not documented and varies by language and revision.
- The 0.90–0.95 cosine "near-duplicate" threshold for memory dedup is a starting heuristic, not a measured value for any specific model; calibrate it.
- The iOS app memory ceiling on an 8 GB A19 device is not a published number; the "2–3 GB usable" figure used in §4.2 is an approximation.
- The specific figures for `google/embeddinggemma-2` (1.10 GB MLX 4-bit, 485 MB LiteRT full, 165 MB LiteRT text-only) are **measured file sizes**, but I have not verified that the MLX 4-bit conversion actually quantizes the vision and audio towers — the 1.10 GB figure is large enough relative to 740M params that it may not.
- `ibm-granite/granite-embedding-311m-multilingual-r2`'s 32K context comes from its model card; the MTEB metadata says 8,192. Discrepancy unresolved.
- `jina-embeddings-v5-text-nano`'s context is 32K per its card but 8,192 per MTEB metadata. Discrepancy unresolved.
