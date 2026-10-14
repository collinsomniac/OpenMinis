# MLX on iOS — ecosystem, upstream leverage, and what we should adopt

**Compiled:** 2026-10-12 (all GitHub metrics fetched live from the GitHub REST API on this date)
**Audience:** the maintainers of our forked iOS on-device-LLM app.

**Our situation, stated precisely (baseline for every recommendation below):**

| Aspect | What we have today |
|---|---|
| App | Fork of an open-source iOS app that runs LLMs on-device via **MLX Swift** |
| SwiftPM deps | `mlx-swift-lm` pinned at **3.32.3**, `mlx-swift` **0.32.3**, `swift-transformers`, `swift-huggingface` |
| Products linked | `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`, `MLX` |
| Model library | A folder of MLX safetensors repos downloaded from Hugging Face |
| Integration | `ProviderType.localMLX` chat provider; background-URLSession model downloader; single-resident chat model with admission control; KV-cache precision control; session pool with prefix reuse via MLX's `PromptCacheReusePolicy`; native tool calling |
| Next step | **Embedding models as a second kind of local model** (text + multimodal) |

Two headline findings before the detail:

1. **Our pin predates a correctness fix.** `mlx-swift-lm` 3.32.3 shipped 2026-09-30; the EmbeddingGemma bidirectional-attention fix landed **2026-10-07**. We are 7 days behind a bug that makes EmbeddingGemma-class embeddings *wrong* (cosine 0.45–0.70 vs the reference). See §5.
2. **Most of what we are about to hand-roll for embeddings already exists upstream** — a registry, six pooled architectures, pooling strategies, reranker support, component-on-demand loading, and a wired-memory admission-control policy system. See §5 and §8.

---

## 1. The MLX Swift stack as it stands

### 1.1 Org status and repo inventory

`ml-explore` is the **Apple-operated** GitHub org (org description: *"Machine learning research on your laptop or in a data center - by Apple"*, https://github.com/ml-explore). It has 11 repositories and 6 public members. Apple links to it from `developer.apple.com` (§2).

| Repo | Kind | What it provides | Created | Latest tag (date) | Releases /90d | Commits /90d | Open issues (total / excl. PRs) | Stars | Last push |
|---|---|---|---|---|---|---|---|---|---|
| [`ml-explore/mlx`](https://github.com/ml-explore/mlx) | first-party framework (C++/Metal core, Python API) | The array framework itself; Metal kernels; `mlx_lm` lives separately in `mlx-lm` | 2023-11-28 | `v0.32.3` (2026-09-29) | 3 | 450 | 110 / 87 | 28,736 | 2026-10-12 |
| [`ml-explore/mlx-swift`](https://github.com/ml-explore/mlx-swift) | **library** (MIT) | Swift API: `MLX`, `MLXNN`, `MLXOptimizers`, `MLXRandom`, `MLXFast` (custom Metal kernels), `WiredMemory` coordinator, `Memory` limits. Vendored C++ `mlx` + `metal-cpp` under `Source/Cmlx` | 2023-12-12 | `0.32.3` (2026-09-30) | 2 | 26 | 62 / 37 | 2,059 | 2026-10-12 |
| [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) | **library** (MIT) | Model implementations + serving primitives: `MLXLLM`, `MLXVLM`, `MLXLMCommon`, `MLXEmbedders`, `MLXRerankers`, `MLXHuggingFace`, `MLXFoundationModels`, `MLXGuidedGeneration`, `MLXScriptedLM`, plus helper/test products | 2025-10-02 | `3.32.3` (2026-09-30) | 1 | 180 | 104 / 69 | 834 | 2026-10-12 |
| [`ml-explore/mlx-swift-examples`](https://github.com/ml-explore/mlx-swift-examples) | **examples** (MIT) | Runnable apps + CLI tools. See §1.3 | 2024-02-22 | `2.29.1` (2025-10-16) | 0 | **0** (last commit 2026-06-15) | 43 / 32 | 2,676 | 2026-07-20 |
| [`ml-explore/mlx-lm`](https://github.com/ml-explore/mlx-lm) | first-party (Python) | Python LLM/VLM runner, server, MTP | 2025-03-11 | `v0.31.3` (2026-04-22) | — | — | 230 | 7,275 | 2026-10-10 |
| [`ml-explore/mlx-examples`](https://github.com/ml-explore/mlx-examples) | examples (Python) | Python-side model zoo | 2023-11-28 | — | — | — | 184 | 9,007 | 2026-04-06 |
| [`huggingface/swift-transformers`](https://github.com/huggingface/swift-transformers) | **library** (Apache-2.0) | Tokenizers (BPE/Unigram/WordPiece) + HF config/tokenizer loading | 2023-05-11 | `1.3.5` (2026-10-09) | 2 | 16 | 36 / 17 | 1,361 | 2026-10-12 |
| [`huggingface/swift-huggingface`](https://github.com/huggingface/swift-huggingface) | **library** (Apache-2.0) | Hub client + Inference Providers; now depends on `swift-xet` | 2025-10-09 | `1.0.0` (2026-10-09) | 7 | 36 | 5 | 178 | 2026-10-12 |

> **On "not for production":** I could not find a literal "not for production" string anywhere in the `ml-explore` org (GitHub code search for `org:ml-explore "not for production"` → 0 hits). What the sources *do* say:
> - `mlx-swift` README positions it as *"making research and experimentation easier on Apple silicon"*.
> - The `mlx` README: *"MLX is designed by machine learning researchers for machine learning researchers … We intend to make it easy for researchers to extend and improve MLX with the goal of quickly exploring new ideas."*
> - The `mlx-swift-examples` README explicitly states the reusable libraries **moved out** to `mlx-swift-lm`: *"`MLXLMCommon`, `MLXLLM`, `MLXVLM` and `MLXEmbedders` have moved to a new repository containing only reusable libraries."* → **`mlx-swift-examples` is the "examples, not production" surface; the libraries are the production surface.**
> - `mlx-swift-lm` is on major version 3 with a documented breaking-change upgrade path and a formal release-planning issue (`#648 "Next Release"`), i.e. it is treated as a real library, but it *is* still a fast-moving 3.x.
> - [unverified] Any claim that Apple markets `mlx-swift-lm` as production-ready for shipping App Store apps. The evidence points the other way (§2).

### 1.2 `mlx-swift-lm` library split (exact, from `Package.swift` on `main`, fetched 2026-10-12)

Platforms: `macOS 14 / iOS 17 / tvOS 17 / visionOS 1`. `swift-tools-version: 6.2`.
Dependencies on `main`: **only** `mlx-swift` (`.upToNextMinor(from: "0.32.3")`) and `swift-syntax` (`602.0.0..<"604.0.0"`). Tokenizer/downloader packages were **decoupled in 3.0** — that is why we depend on `swift-transformers`/`swift-huggingface` separately.

| Product | Target | Role | Notes relevant to us |
|---|---|---|---|
| `MLXLMCommon` | `Libraries/MLXLMCommon` | Core: `ModelContainer`, `ChatSession`, `KVCache` family, registries, media processing | Everything we currently use. Also hosts `PromptCacheReusePolicy.swift`, `KVCacheStatus`, wired-memory policies |
| `MLXLLM` | `Libraries/MLXLLM` | Text LLM architectures (`LLMTypeRegistry`, `LLMRegistry`) | ~30 architecture keys registered today (`llama`, `gemma…gemma4`, `qwen2/3/3_moe/3_next/3_5…`) |
| `MLXVLM` | `Libraries/MLXVLM` | Vision-language architectures + processors | `VLMModelFactory`, `VLMProcessorLoadingRegistry` |
| `MLXEmbedders` | `Libraries/MLXEmbedders` | **Text embedding models**, pooling, `EmbedderTypeRegistry`, `EmbedderRegistry`, `EmbedderModelContainer` | Directly relevant to our next step — see §5 |
| `MLXRerankers` | `Libraries/MLXRerankers` | Cross-encoder reranker factory | `RerankerModelFactory` |
| `MLXHuggingFace` | `Libraries/MLXHuggingFace` (+ `MLXHuggingFaceMacros`) | `#hubDownloader()`, `#huggingFaceTokenizerLoader()`, `#huggingFaceLoadModelContainer` macros | This is the product we link as `MLXHuggingFace` |
| `MLXFoundationModels` | `Libraries/MLXFoundationModels` | **Bridge MLX → Apple's `FoundationModels.LanguageModel`**, gated behind the `FoundationModelsIntegration` trait (default-on) | Requires **iOS/macOS/visionOS 27.0 SDK**. Big architectural signal — see §2 |
| `MLXGuidedGeneration` | `Libraries/MLXGuidedGeneration` | Grammar-constrained generation (JSON Schema or EBNF) | Alternative to our own tool-calling enforcement |
| `MLXCXGrammar` | `Libraries/MLXCXGrammar` | C++ xgrammar shim (not a product) | Implementation detail of the above |
| `MLXScriptedLM` | `Libraries/MLXScriptedLM` | Scripted tokenizers/models for tests & stubs without weights | Useful for our CI |
| `BenchmarkHelpers`, `IntegrationTestHelpers` | — | Test/benchmark scaffolding | — |

> ⚠️ **Naming correction:** the task text mentions `MLXLMHuggingFace`. That target **does not exist** on `main` or in any 3.x tag. The downloader/tokenizer integration product is **`MLXHuggingFace`** (with a `MLXHuggingFaceMacros` target behind it). If our `Package.swift` references `MLXLMHuggingFace`, it is resolving against a stale/2.x-era name.

### 1.3 `mlx-swift-examples` — what it actually ships

| Path | Type | Notes |
|---|---|---|
| `Applications/LLMBasic` | iOS + macOS app | Minimal: load model, eval one prompt |
| `Applications/LLMEval` | iOS + macOS app | Download from HF, generate, preset prompts, tool integration, run statistics |
| `Applications/MLXChatExample` | iOS + macOS app | **The closest analogue to our app**: SwiftUI, LLM + VLM, image/video input, model caching + memory management, async generation with cancellation, `DownloadProgressView`, `GenerationInfoView`, `LMModel`, `MLXService` |
| `Applications/LoRATrainingExample` | macOS only | LoRA fine-tuning |
| `Applications/StableDiffusionExample` | iOS + macOS | SDXL Turbo |
| `Applications/MNISTTrainer` | iOS + macOS | LeNet |
| `Numerical/{CurveFit,HeatTransfer,Mandelbrot}` | macOS | MLX without a model — `compile`, custom Metal kernels |
| `Tools/llm-tool`, `Tools/image-tool`, `Tools/embedder-tool`, `Tools/mnist-tool`, `Tools/LinearModelTraining` | CLI | **`embedder-tool`** indexes Markdown into a JSON embedding index; flags `--strategy/--normalize/--layer-norm` |
| `Libraries/{StableDiffusion,MLXMNIST}` | libraries | Still published from this repo |

**Health warning:** `mlx-swift-examples` has had **0 commits in the last 90 days**, its last commit is **2026-06-15**, and its last release tag is **2.29.1 (2025-10-16)**. Treat it as a reference to read, not a dependency to track. (It is still 2,676★ because it is the canonical entry point.)

### 1.4 Newer things on `main` that did not exist in older guides

- **Package traits** (Swift 6.2): `FoundationModelsIntegration` default-on; disabling it compiles `MLXFoundationModels` to an empty library so consumers on pre-27 OS versions can still use `MLXLLM`/`MLXLMCommon`/`MLXEmbedders`.
- **Agent-facing docs in-repo**: `skills/mlx-swift/SKILL.md` + `references/*.md` in `mlx-swift`, and `skills/mlx-swift-lm/references/{embeddings,kv-cache,generation,concurrency,model-container,lora-adapters}.md`. These are the most current, most accurate descriptions of the API that exist — better than the docc in places (they document `cacheStatus`, `KVCacheStatus`, `makePromptCache`, `savePromptCache`, `RotatingKVCache.toQuantized()` → `fatalError`).
- **`MLXRerankers`**, **`MLXGuidedGeneration`**, **`MLXFoundationModels`**, **`MLXScriptedLM`** — all new in the 3.x line.
- **Wired-memory coordinator** (`WiredMemory.swift`, `WiredMemoryManager`, `WiredMemoryTicket`, policies) — §5, §8.

---

## 2. Is MLX an Apple-endorsed / first-party path?

**Verdict: MLX is first-party *Apple research* software and Apple actively links to it — but Apple's own production, shipping-app story for on-device inference on iOS is Core ML / Core AI / Foundation Models, and every MLX WWDC session is framed around the Mac.**

### 2.1 Evidence for endorsement

| Evidence | Source | What it says |
|---|---|---|
| Org ownership | https://github.com/ml-explore | Org description: *"Machine learning research on your laptop or in a data center - by Apple"*. 11 repos, 6 members. Maintainer `davidkoski` is an Apple engineer and the de-facto approver (comment in `mlx-swift-lm` #682: *"there is a small list of people who can approve PRs. Currently all are apple employees."*) |
| Apple links to it | https://developer.apple.com/machine-learning/ | Dedicated **"MLX framework"** section: *"MLX is an open-source array framework that lets you experiment with, training, researching, and fine-tuning generative models on Apple Silicon. It supports **Metal 4** and **GPU Neural Accelerators** for maximum performance, and can scale training across multiple Macs with **RDMA over Thunderbolt**, making it an incredible way to explore cutting-edge machine learning innovations **on Mac**."* |
| Apple-hosted project site | https://mlx-framework.org/ (© Apple Inc.) | *"MLX can be run on any Apple platform that supports Metal"* — Python, C++, and **MLX Swift** bindings; *"Designed for unified memory"*; *"Multi-device support (CPU or GPU)"* |
| WWDC sessions | https://developer.apple.com/videos/all-videos/?q=MLX | **WWDC25-315** *"Get started with MLX for Apple silicon"* (19:29) · **WWDC25-298** *"Explore large language models on Apple silicon with MLX"* (20:08) · **WWDC26-232** *"Run local agentic AI **on the Mac** using MLX"* (13:37) · **WWDC26-233** *"Explore distributed inference and training with MLX"* (22:06) · **WWDC26-328** *"Explore numerical computing in Swift with MLX"* (14:31) |
| Apple bridges MLX *into* its own framework | `MLXFoundationModels` in `mlx-swift-lm` | Turns an MLX model into a `FoundationModels.LanguageModel` usable with `LanguageModelSession`. Requires the **iOS 27.0 SDK**. This is the strongest "Apple is integrating, not competing" signal on `main` today |
| M5 hardware narrative | WWDC26-232 transcript | *"The M5 chip introduces dedicated Neural Accelerators, and MLX can target them … matrix multiplication four times faster on M5 compared to M4 … Taking advantage of Neural Accelerators requires no special arguments or code changes on your part, MLX selects the best kernel for the available hardware."* |

### 2.2 The honest counterpoint

**MLX uses the GPU (Metal) and CPU only. The Apple Neural Engine (ANE) is not reachable from MLX at all.**

| Claim | Evidence |
|---|---|
| No ANE support in MLX | GitHub code search `repo:ml-explore/mlx "Neural Engine"` → **0 results**. The only "Neural Accelerator" references are the **GPU** NAX kernels (`mlx/backend/metal/kernels/*_nax.metal`, `steel/gemm/gemm_nax.h`, `steel/attn/nax.h`). MLX device list is CPU + GPU (README: *"currently the CPU and the GPU"*) |
| NAX is a *GPU* feature with an OS gate | `mlx/backend/metal/device.cpp::is_nax_available()` — requires `macOS/iOS/tvOS/visionOS 26.2+` **and** GPU arch generation `>= (arch == 'p' ? 18 : 17)`. On iPhone 16 Pro (A18 Pro) this mis-detected and produced gibberish output (`mlx-swift-examples` #462, 10 comments), fixed by `ml-explore/mlx` **PR #3083 "Fix nax condition for iphone"** (merged 2026-01-29) |
| Apple's own iOS production path is elsewhere | https://developer.apple.com/core-ai/ — *"**Core AI** is a comprehensive set of technologies purpose-built for Apple silicon. Load and run AI models entirely on device … Models are automatically specialized for the hardware they run on, with **ahead-of-time compilation** support for instant load times. Fine-grained control over inference memory, zero-copy data paths, and stateful execution … across **iPhone, iPad, Mac, and Apple Vision Pro**."* Core ML (`MLModel`, iOS 11+) is still documented and maintained. Foundation Models is Apple's built-in on-device LLM path. |
| Mac framing everywhere | Every WWDC MLX session title says Mac / "Apple silicon"; the Apple ML page says "on Mac" |

### 2.3 What we gain and lose vs the alternatives

| Dimension | MLX Swift | Core ML / Core AI | llama.cpp (GGUF) |
|---|---|---|---|
| Compute units | GPU (Metal) + CPU. **No ANE** | CPU + GPU + **ANE**, chosen per-op by the runtime | CPU + Metal GPU (partial), no ANE |
| Model coverage | The fastest-moving open-weight zoo for Apple silicon; VLM + embedder + reranker + LoRA training in one stack | You must convert/author each model; `coremltools`/Core AI PyTorch extensions | Huge GGUF catalogue, frozen at conversion time |
| Quantization | MLX 4/6/8-bit affine, DWQ, ParoQuant, TurboQuant (fork), KV-cache quantization | Palettization/quantization via Core AI Optimization | Q4_K/Q5_K/Q8_0, i-quants |
| Memory control | `Memory.memoryLimit` / `Memory.cacheLimit` / `Memory.snapshot()` + `WiredMemoryManager` tickets & admission policies | Documented "fine-grained control over inference memory", AOT | `--no-mmap`, `n_gpu_layers`; coarse on iOS |
| Platforms | macOS 14 / iOS 17 / tvOS 17 / visionOS 1 (SwiftPM) | iOS 11+ (Core ML); Core AI is the new surface | iOS via C++/Swift wrappers |
| Preview/dev loop | **Cannot run in the iOS Simulator** (needs a modern `MTLGPUFamily`) — Apple's own doc says so | Simulator supported | Simulator supported (CPU) |
| Maturity signal | Apple research org, MIT, active; but 3.x major with breaking changes and no "production" positioning | Apple's own production framework, WWDC keynote surface | 130,947★, 2,551 open issues, v0.6.0 (2026-10-05) |
| Our fit | We're already here, with modeling features Core ML can't express (native tool calling, prefix-reuse session pool, VLM) | Would mean re-authoring the whole stack | Would mean abandoning MLX tool-calling + session-pool work; GGUF download UX we already solved |

**Practical reading:** MLX is an *endorsed, Apple-run, research-grade* framework. For a production iOS app in 2026 the "official" path is **Core AI** (or Core ML), and Apple is now actively *bridging* MLX into `FoundationModels` (iOS 27 SDK) rather than telling you MLX is the shipping path. Staying on MLX costs us the ANE and the Simulator; it buys us model breadth and velocity. That is a defensible trade for a multi-provider local-model app — but it should be a conscious one, documented in the repo, with Core AI re-evaluated when `MLXFoundationModels`'s OS floor (iOS 27) becomes our minimum.

---

## 3. iOS vs macOS for MLX

| Dimension | macOS | iOS | Consequence for us |
|---|---|---|---|
| **Unified memory** | UMA, effectively unbounded wired limit | **Also UMA** (Apple silicon) — MLX's unified-memory model is *not* degraded. What differs is the **budget**, not the architecture | The MLX docs' "designed for unified memory" claim holds on iPhone. Don't attribute iPhone memory problems to non-UMA |
| **Memory limits / jetsam** | No per-process jetsam; `recommendedMaxWorkingSetSize()` is a soft guide | **jetsam** kills the process. `mlx-swift/Source/MLX/Documentation.docc/Articles/running-on-ios.md` says so explicitly and points to the **Increased Memory Limit** entitlement (`com.apple.developer.kernel.increased-memory-limit`) | Mandatory: set `MLX.Memory.cacheLimit` (docs suggest as low as 20 MB) and use `Memory.snapshot()`; add the entitlement |
| **Per-process ceiling** | n/a | Third-party analysis (modelfit.io, 2026-06-12) puts iPhone RAM at 6 GB (iPhone 15/A16), 8 GB (15 Pro/16), 12 GB (17 Pro) and says *"iOS needs 2–3 GB for system operations, leaving the remainder for AI models"*. GGUF-app practical ceilings quoted as ~2B / 4B / 4B / 9B params by tier. **All [unverified]** — the numbers are third-party and device-specific | Plan model admission around a ~50–60 % RAM budget without the entitlement; verify on our own target devices |
| **Real measured MLX embedder footprint on iOS** | — | `rurza` in `mlx-swift-lm` PR #684: iPhone 14 Pro (6 GB), EmbeddingGemma-2 **text tower only** (~176 MB of weights): **load 0.59 s, ~208 s per 1,000 docs @512 tokens, peak footprint ~391 MB** | Excellent calibration data for our embedder resident-model budget |
| **Background execution** | Long-running processes fine | App suspended within seconds of backgrounding; no long compute; `BGProcessingTask` is opportunistic at best | Any embedding job over a large corpus must be chunked and resumable, and must not assume a foreground window. This is an argument for **incremental, checkpointed indexing** rather than "embed the library then return" |
| **`MTLDevice` differences** | Full GPU families, macOS-only APIs | Smaller family set; **the iOS Simulator does not expose a modern `MTLGPUFamily` at all** — MLX will assert (`Dispatch Threads with Non-Uniform Threadgroup Size is not supported`). Apple's recommended workarounds: `Mac (Designed for iPad)` destination, or a multiplatform target developed on Mac | Our CI/dev loop cannot use the Simulator for anything touching `MLXArray`. Budget for physical-device testing (or Mac-catalyst) in CI |
| **Metal kernel coverage across GPU families** | Broad | Gated by `MTLGPUFamily` **and** OS version. NAX tensor-accelerator kernels require **OS 26.2+** and arch gen ≥17/18 → effectively **A19/M5-class GPUs**; A18 Pro mis-detected and corrupted output until `mlx` PR #3083 (2026-01-29) | Kernel *correctness* regressions on specific iPhone GPU generations are a live risk class. Pin `mlx-swift` and keep a smoke test on at least one older iPhone |
| **ANE reachability** | Not reachable from MLX | Not reachable from MLX | If ANE-dependent workloads are ever required, MLX is the wrong tool — see §6 |
| **Model size ceilings** | Dictated by RAM (512 GB Macs run 1.6 T-param DeepSeek sharded over Thunderbolt) | Dictated by jetsam; high single-digit GB at best on 12 GB devices, realistically low-single-digit GB without the entitlement | Our "single resident chat model + admission control" design is the right architecture, and it should stay that way |
| **Open iOS-specific bugs on `mlx-swift` (2026-10-12)** | — | [#497 crash on iOS 17](https://github.com/ml-explore/mlx-swift/issues/497) (open) · [#494 iOS 26.2 launch crash from `Logger.isEnabled`](https://github.com/ml-explore/mlx-swift/issues/494) (open PR) · [#485 app hangs before `main()` on a physical device when linking MLX](https://github.com/ml-explore/mlx-swift/issues/485) (open; iPhone 17 Pro Max, iOS 27.0) · [#342 `constexpr if` C++17 Metal warning](https://github.com/ml-explore/mlx-swift/issues/342) · [#349](https://github.com/ml-explore/mlx-swift/issues/349)/[#460](https://github.com/ml-explore/mlx-swift/issues/460) `default.metallib` bundling (Tuist / `swift test`) | Note **#491 is already fixed by our pin**: 0.32.3 (2026-09-30) is explicitly *"Patch release for #491 / #493 — applications linking to mlx-swift would crash on launch on macOS/iOS earlier than 26.4"* |
| **Memory-pressure failure mode** | Slow / swap | Hard kill | `mlx-swift-lm` [#498 gemma3n_E2B hang + Metal-compiler jetsam under memory pressure](https://github.com/ml-explore/mlx-swift-lm/issues/498) is an open example: repeated `MTLCompiler … XPC_ERROR_CONNECTION_INVALID` after a jetsam restart |

---

## 4. How shipping apps actually do inference

### 4.1 App Store / closed apps

Facts below are from the modelfit.io ranking (*"App facts verified against App Store listings and official sites on 2026-06-12"*) plus GitHub where the app is open source. Treat the third-party write-up as **[unverified]** except where the GitHub numbers corroborate it.

| App | Engine | Model management | Memory / thermal | Presentation |
|---|---|---|---|---|
| **PocketPal AI** ([a-ghorbani/pocketpal-ai](https://github.com/a-ghorbani/pocketpal-ai), 8,612★, MIT, pushed 2026-10-12, 214 open issues) | llama.cpp / GGUF | In-app Hugging Face search; any GGUF; lowest OS floor (iOS 15.1+) | Not documented publicly; per-model load/unload in-app | "Best free all-rounder"; vision + on-device TTS; universal iPhone/iPad/Mac |
| **Private LLM** | Proprietary runtime with OmniQuant/GPTQ quantization | **Curated library organised by RAM tier**; only app curating uncensored variants | RAM-tier model gating built into the catalogue | $4.99 one-time; deep Siri/Shortcuts; "fastest curated models" |
| **Locally AI** (acquired by LM Studio, early 2026) | **MLX + Apple Foundation Models (iOS 26+)** | Curated MLX models plus Apple's built-in model with **zero download** | LM Studio's "LM Link" (June 2026) tunnels to a Mac — **offload the big model to the desktop** | "Best MLX app"; hybrid local/desktop |
| **Enclave** | llama.cpp / GGUF | Any GGUF via HF search; free for local models | Voice pipeline on-device; Pro tier only for *cloud* | Voice chat + PDF/text/image/code context; iPhone/iPad/Mac/Vision Pro/Watch |
| **Google AI Edge Gallery** | **LiteRT / Google AI Edge** | Gemma family only (incl. Gemma 4) | Google's own runtime | Official Google app; image understanding, audio transcription, agent skills |
| **Off Grid** | llama.cpp + on-device Stable Diffusion | Any GGUF + Whisper voice + doc KB | Self-described early (0.0.x) | "Most features in one app" |
| **Liquid Apollo** (was Apollo AI) | Liquid LEAP (LFM2) | Local LEAP models + optional OpenRouter/Ollama/LM Studio | Hybrid local/cloud offload | One app for both worlds |
| **fullmoon** (Mainframe) | **MLX** | — | — | Free MLX app, "updates rarely" |
| **MLC Chat** | MLC / TVM | — | — | Pioneered fast iPhone inference; **model lineup not refreshed since 2024** |
| **LLM Farm** ([guinmoon/LLMFarm](https://github.com/guinmoon/LLMFarm), 2,081★, MIT, last push **2026-01-30**, 46 open issues; core at [guinmoon/llmfarm_core.swift](https://github.com/guinmoon/llmfarm_core.swift), 283★, last push 2025-12-09) | GGML/llama.cpp | Local GGUF in Files app | — | **Currently delisted from the App Store** ("temporarily unavailable") |

### 4.2 Open-source Swift projects worth reading

| Project | Stars | Last push | What to read it for |
|---|---|---|---|
| [tattn/LocalLLMClient](https://github.com/tattn/LocalLLMClient) | 219 | 2026-08-26 | **A single Swift API over both llama.cpp and MLX** for iOS/macOS/Linux — the cleanest reference for provider abstraction. Also [theJayTea/LocalLLMClient-JT](https://github.com/theJayTea/LocalLLMClient-JT) adds Qwen3-VL for both backends |
| [SharpAI/SwiftLM](https://github.com/SharpAI/SwiftLM) | 779 | 2026-10-12 | MLX Swift **OpenAI-compatible inference server** on Apple Silicon, incl. **SSD weight streaming** |
| [nanguoyu/minirun-app](https://github.com/nanguoyu/minirun-app) | 64 | 2026-09-12 | Extreme weight-streaming from SSD on iPhone 16 Pro — the hack for models bigger than RAM |
| [brequinn/GoLocalLLM](https://github.com/brequinn/GoLocalLLM) | 7 | 2025-12-23 | Minimal MLX LLM+VLM iOS app that **auto-downloads a small model on first launch** |
| [ibrahimcetin/MLXSampleApp](https://github.com/ibrahimcetin/MLXSampleApp) | 43 | 2025-03-05 | Minimal MLX iOS/macOS app |
| [rayl15/OpenVision](https://github.com/rayl15/OpenVision) | 160 | 2026-10-04 | Five backends in one iOS app, incl. on-device MLX + cloud |
| [Eric-Terminal/ETOS-LLM-Studio](https://github.com/Eric-Terminal/ETOS-LLM-Studio) | 208 | 2026-10-11 | GGUF on iOS **and Apple Watch**, offline |
| [rryam/VecturaKit](https://github.com/rryam/VecturaKit) | 324 | 2026-08-31 | **The embeddings-side reference**: on-device vector DB, hybrid BM25+vector search, pluggable embedders (`MLXEmbedder` via [VecturaMLXKit](https://github.com/rryam/VecturaMLXKit), `SwiftEmbedder` via [VecturaEmbeddingsKit](https://github.com/rryam/VecturaEmbeddingsKit), `NLContextualEmbedder`, `OpenAICompatibleEmbedder`), auto dimension detection, `vectura-cli` |
| `mlx-swift-examples` `Applications/MLXChatExample` | — | 2026-06-15 | The canonical SwiftUI MLX chat architecture (MVVM, `MLXService`, download progress, generation info) |

### 4.3 Patterns worth copying

1. **One resident model, explicit eviction.** Every credible app does this. Our single-resident + admission-control design matches the state of the art; keep it and extend it to embedders as a *second residency class* rather than a second pool.
2. **Model catalogue organised by RAM tier.** Private LLM's differentiator is literally "curated builds organised by how much RAM your iPhone has". Our model library should carry a declared `minRAMGB` (or derived from safetensors byte size + KV estimate) and the UI should refuse/warn before a 4 GB download on a 6 GB device. This is cheap and it is the single most-copied UX pattern in the category.
3. **Auto-download a tiny default on first launch.** GoLocalLLM ships Qwen3-0.6B automatically. Removes the empty-state cliff.
4. **Download UX as a first-class view.** `MLXChatExample` has a dedicated `DownloadProgressView`; our background-URLSession downloader should expose progress, pause/resume, and byte-accurate sizes (the `MLXHuggingFace`/`swift-huggingface` `Progress` handler already gives `fractionCompleted`; `mlx-swift-lm` PR #551 adds *reading-weights* progress too — see §5).
5. **Desktop/hybrid offload.** Locally AI's LM Link + Liquid Apollo's Ollama backend. Cheap differentiator if our app already speaks OpenAI-compatible endpoints.
6. **Zero-download fallback.** Locally AI's use of Apple's built-in Foundation Models for the "no model installed" case is a strong pattern — and on iOS 27+ `MLXFoundationModels` makes the *inverse* available too.
7. **Voice-first UX (Enclave).** On-device STT/TTS + document context is the most-differentiated consumer framing in the category.
8. **Persist and reuse prefixes.** We already do this; the upstream `PromptCacheReusePolicy` enum (`.prefillAll`, `.appendSuffix`, `.appendSuffixToMain`, `.appendMediaSuffix`, `.trimToCommonPrefix`, `.rebuild`) is the vocabulary to keep using, and `savePromptCache`/`loadPromptCache` (safetensors + metadata) give us cross-launch persistence for free.

---

## 5. What upstream has that we should adopt, not rebuild

Everything below was verified against live GitHub data on **2026-10-12**.

### 5.1 `MLXEmbedders` — exists, is maintained, and already does most of what we need

**What it is:** `Libraries/MLXEmbedders` in `mlx-swift-lm`, a first-party **library** (product `MLXEmbedders`) providing text embedding models, pooling, a two-level registry, a thread-safe container, and reranker hooks.

**Registered `EmbeddingModel` types today** (from `Libraries/MLXEmbedders/ModelFactory.swift`, `EmbedderTypeRegistry.shared`):

| `model_type` | Creator | Notes |
|---|---|---|
| `bert` | `createBertCompatibleModel` | Branches to `BertSequenceClassificationRerankerModel` / `BertRerankerModel` when `isSequenceClassification` |
| `roberta`, `xlm-roberta` | `createBertCompatibleModel` | Reranker path |
| `distilbert` | `BertModel` | — |
| `nomic_bert` | `NomicBertModel(pooler: false)` | Nomic v1 / v1.5 |
| `qwen3` | `Qwen3Model` | Qwen3-Embedding |
| `lfm2` | `LFM2BidirectionalModel` | LFM2.5 bidirectional encoders (Embedding **and ColBERT**); branches on the `"mlx"` head |
| `gemma3`, `gemma3_text`, `gemma3n` | `EmbeddingGemma` | EmbeddingGemma |

**Pooling** (`Pooling.swift`): strategies `.mean`, `.cls`, `.first`, `.last`, `.max`, `.none`; loaded from `1_Pooling/config.json` (sentence-transformers spec, with absent key → `false`), falling back to the model's declared `poolingStrategy`, then `.none`. Options: `mask:`, `normalize:`, `applyLayerNorm:`. `PoolingConfiguration` decodes `word_embedding_dimension` and the four `pooling_mode_*` flags.

> ⚠️ **Doc drift:** `skills/mlx-swift-lm/references/embeddings.md` still lists only `bert`, `nomic_bert`, `qwen3` as supported architectures and does not list `lfm2`/`gemma3`. **The source is ahead of the reference doc.** Trust `EmbedderTypeRegistry`.

**Registry** (`EmbedderRegistry`, `AbstractModelRegistry`): a **pre-registered catalogue** of 15+ models — BGE micro/small/base/large, GTE tiny, MiniLM L6/L12, Nomic v1/v1.5, multilingual-E5 small, Snowflake XS/L, BGE-M3, mxbai-embed-large-v1, `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`. API: `EmbedderRegistry.shared.configuration(id:)`, `.models` → collection, `register(configurations: [...])` to extend, `contains(id:)`.

**Approximate memory table from upstream's own docs:** micro ~17 M ≈ 70 MB, small ~33 M ≈ 130 MB, base ~110 M ≈ 440 MB, large ~335 M ≈ 1.3 GB.

**Rerankers:** `Libraries/MLXEmbedders/Reranker.swift` (package-internal scoring policies `.singleLogit`, `.classLogit`, `.binaryMargin`, `.softmaxProbability`; input kinds `bert`/`xlmRoberta`) plus the public `MLXRerankers` product with `RerankerModelFactory`. `MLXLLM` also has `Models/JinaReranker.swift`.

**Verdict: ADOPT, do not rebuild.** Use `EmbedderModelFactory.shared.loadContainer(...)` + `EmbedderModelContainer.perform { context in … }` + `context.pooling(...)`, exactly as we use `ModelContainer` for chat. Extend the catalogue with `register(configurations:)` rather than writing a parallel registry.

### 5.2 The PRs the task asked us to verify

| Item in task | Verified identity | State on 2026-10-12 | Reactions / comments | What it does | Our move |
|---|---|---|---|---|---|
| "EmbeddingGemma 2 support PR #684" | ✅ [`#684 "Add EmbeddingGemma 2 full support"`](https://github.com/ml-explore/mlx-swift-lm/pull/684), author `aleroot`, created 2026-10-07, labels `cat-model` + `needs-review`, `draft: false` | **OPEN — NOT MERGED** (last updated 2026-10-12) | **9 comments, 2 reactions** | Adds `EmbeddingGemma2`: text + **image + video + audio** mapped into one embedding space, interleavable. Bidirectional encoder, so the VLM factory cannot load it. Reported cosine **0.9999** for audio/video/interleaved and **0.99995** at 2,880 and 7,490 tokens vs the Transformers SDPA path | **VENDOR / WATCH — do not wait.** See the comment thread below; the API-shape discussion is unresolved |
| "bidirectional-attention bug fix #654" | ✅ [`#654 "MLXEmbedders: use bidirectional attention in EmbeddingGemma"`](https://github.com/ml-explore/mlx-swift-lm/pull/654), author `MBark286`, fixes [`#638`](https://github.com/ml-explore/mlx-swift-lm/issues/638) | **CLOSED & MERGED 2026-10-07T16:18:25Z** | 0 comments, 1 reaction | EmbeddingGemma's `config.json` sets `"use_bidirectional_attention": true`; the Swift backbone ignored it and built **causal** masks, so every token only saw preceding tokens. Against transformers 5.17 float32 with `google/embeddinggemma-300m`, final embeddings had **cosine 0.45–0.70**. Adds `createBidirectionalAttentionMask(length:halfWindow:paddingMask:)` in `MLXEmbedders/AttentionMask.swift`; returns `.none` when no window and no padding | **CRITICAL — our 3.32.3 pin predates this merge (2026-09-30 < 2026-10-07).** Any EmbeddingGemma embedding we produce today is silently wrong. Bump to a commit ≥ 2026-10-07 or vendor the patch |
| "load model components on demand #580" | ✅ [`#580 "Load model components on demand, starting with MuseGlimmer's vision encoder"`](https://github.com/ml-explore/mlx-swift-lm/pull/580), author `aleroot`, created 2026-08-26 | **CLOSED & MERGED 2026-10-12T16:09:55Z** (merged today) | 3 comments, 0 reactions | Lazy/on-demand loading of model *components*, applying MLX's lazy-evaluation philosophy to loading: text-only users avoid materialising vision/audio towers. Also carries decode-path fusions for Muse-Glimmer-30B. Predecessor [`#679 "Introduce component-aware checkpoint loading"`](https://github.com/ml-explore/mlx-swift-lm/pull/679) merged 2026-10-05 | **ADOPT (once released).** This is exactly the mechanism that makes a *text-only* EmbeddingGemma-2 load viable without editing `config.json` |

**Key snippets from the #684 thread (verbatim, they explain the state and the design fight):**

- `CodebyCR` (2026-10-08): *"Thanks for this, the results look great! I plan to build on it instead of writing my own port."* — asks that the Gemma 4 encoders (`Gemma4VisionModel`, `Gemma4AudioModel`, `Gemma4MultimodalEmbedder`) be `package` rather than `public`, and proposes an **`MLXMediaEncoders`** target.
- `davidkoski` (Apple, 2026-10-08): on `package` vs `public` — *"I think it can be an individual call per model… I originally suggested `package` to avoid filling the public API with implementation details. I guess another option is to use `_spi`."* and *"I think it is ok to try some things out… make them `package` and expose them later if people want them to be `public` (that is probably the safer route in terms of API)."*
- `rurza` (2026-10-11) — **the single most useful data point for us**: they ran the branch as a **text-only** user on `mlx-community/embeddinggemma-2-4bit` with all vision/audio tensors stripped (~176 MB). **macOS parity:** cosine min 0.9998 / mean 0.9999 on short queries and 512-token docs; 0.99997 at 1k/2k/4k tokens (beyond the sliding window); padded batches match one-by-one at ≥ 0.99994. **iPhone 14 Pro (6 GB): load 0.59 s, ~208 s per 1,000 documents at 512 tokens, peak footprint ~391 MB.** On a 31-doc / 32-query Polish-English retrieval set: MRR 0.94, cross-language 0.90 — identical to full precision in sentence-transformers. They reported three problems (truncated in the thread; the text-only loading issue is the one aleroot responded to).
- `aleroot` (2026-10-12): asks to merge #580 first and adopt its component-loading infrastructure for EmbeddingGemma-2's towers — *"That would let text-only users load the model without modifying config.json."*
- `davidkoski` (2026-10-12): *"Yeah, I will review 580 next."* … then *"#580 is merged"*.
- `aleroot` (2026-10-12, after rebase): *"Tested with `mlx-community/embeddinggemma-2-8bit`. Initial live MLX memory measured **288 MB versus 1.23 GB**. Vision and audio load independently on first use through #580's component infrastructure, so text-only use avoids loading either encoder."*

→ **That last line is the whole ballgame for our next milestone:** a 4× memory reduction for text-only use, delivered by an upstream mechanism we should consume rather than write.

### 5.3 MTP / speculative decoding

| Item | State | Reaction | Verdict |
|---|---|---|---|
| [`#545 "Add Qwen 3.8 support for text, VLM, and MTP speculative decoding"`](https://github.com/ml-explore/mlx-swift-lm/pull/545) | **OPEN** (created 2026-08-17, updated 2026-10-12) | 2 comments, **4 reactions** | WATCH — this is the Qwen3.5-generation MTP work; not merged |
| [`#581 "Add resumable Qwen MTP speculative decoding to ChatSession"`](https://github.com/ml-explore/mlx-swift-lm/pull/581) | **OPEN** | 2 comments, 1 reaction | WATCH |
| [`#279 "Register gemma4_assistant model type so Gemma 4 MTP drafters load through LLMModelFactory"`](https://github.com/ml-explore/mlx-swift-lm/issues/279) | **OPEN** | 6 comments | WATCH |
| [`#606`](https://github.com/ml-explore/mlx-swift-lm/issues/606) / [`#607 "DFlash2 speculative decoding for Qwen3.8-27B"`](https://github.com/ml-explore/mlx-swift-lm/issues/607) | OPEN | 1 comment each, 2 reactions on #607 | WATCH |
| [`#459 "MTP speculative decoding: preserve the target distribution when sampling"`](https://github.com/ml-explore/mlx-swift-lm/issues/459), [`#645 "Expose a public transactional MTP step API for cached/batched callers"`](https://github.com/ml-explore/mlx-swift-lm/issues/645), [`#496 "31B MTP diagnostics never run on a cold CI runner"`](https://github.com/ml-explore/mlx-swift-lm/issues/496), [`#542 "MTP diverges from autoregressive output at temperature 0 on quantized Gemma 4 12B"`](https://github.com/ml-explore/mlx-swift-lm/issues/542) (closed) | mixed | — | Speculative decoding upstream is **active but unsettled**, with known correctness caveats (distribution preservation, quantized divergence). Note the 3.32.3 release notes claim *"massive improves in draft models"* |
| [`#425`](https://github.com/ml-explore/mlx-swift-lm/issues/425) / [`#426 "Add prompt-lookup (n-gram) speculative decoding"`](https://github.com/ml-explore/mlx-swift-lm/issues/426) / [`#643 "Add bounded prompt lookup decoding"`](https://github.com/ml-explore/mlx-swift-lm/pull/643) | OPEN | 0 comments | **Draft-model-free** speedup for repetition-heavy generation. Cheap to try, much better fit for a mobile app than drafter-model MTP (no extra resident weights) |

**Verdict: DON'T BUILD speculative decoding.** It is a moving upstream target with open correctness issues. If we want a mobile-friendly win, watch **#643 (bounded prompt lookup)** — it needs no second model, which matters enormously under a jetsam budget.

### 5.4 KV-cache quantization correctness & new cache strategies

| Item | State | Reaction | What it means for us |
|---|---|---|---|
| [`#652 "[BUG] GLM4MoELite traps when generating with a quantized KV cache (kvBits)"`](https://github.com/ml-explore/mlx-swift-lm/issues/652) → fix [`#671`](https://github.com/ml-explore/mlx-swift-lm/pull/671) | **CLOSED / MERGED 2026-10-06** | 2 comments | A quantized-KV bug class we are exposed to via our KV-precision control. Fixed upstream *after* our 3.32.3 pin |
| [`#81 "Dynamic maybeQuantizeKVCache causes cache COW in TokenIterator"`](https://github.com/ml-explore/mlx-swift-lm/issues/81) | **OPEN since 2025-06-27** | 8 comments | Long-standing: converting `KVCacheSimple` → `QuantizedKVCache` inside `TokenIterator` can leave the caller holding a stale reference, so **external code cannot see the updated cache**. Directly relevant to our session pool + KV precision control. Read this before trusting `kvBits` + externally-held caches |
| [`RotatingKVCache.toQuantized()` is not implemented and `fatalError()`s** | Documented in `skills/mlx-swift-lm/references/kv-cache.md` | — | **Never combine sliding-window (`maxKVSize`) with `kvBits`** via `RotatingKVCache`. Use `KVCacheSimple` + quantization and manage context manually |
| [`#294 "Interest in TurboQuant / rotating quantized KV cache support?"`](https://github.com/ml-explore/mlx-swift-lm/issues/294) | **OPEN** since 2026-05-17 | 3 comments, 1 reaction | A community fork (`RNT56/mlx-swift`, `RNT56/mlx-swift-lm`, branch `schtack/turboquant-kv`) has TurboQuant + rotating quantized KV. Not upstreamed. WATCH |
| [`#424 RotatingKVCache becomes untrimmable once the window wraps`](https://github.com/ml-explore/mlx-swift-lm/issues/424), [`#618`](https://github.com/ml-explore/mlx-swift-lm/issues/618), fix PR [`#622 "Fix exact prefix rewinds in rotating KV caches"`](https://github.com/ml-explore/mlx-swift-lm/pull/622) | OPEN | 1–3 comments | Sliding-window caches + prefix reuse + speculative rollback interact badly. Our session pool should default to non-wrapping caches for prefix reuse |
| [`#629 "RFC: Branchable KV cache with shared-prefix / copy-on-write semantics"`](https://github.com/ml-explore/mlx-swift-lm/issues/629) | **OPEN** since 2026-09-18 | 5 comments | Requested by `slamfinger` (SimiGo). Explicitly notes the missing capability: prompt-cache save/load, `KVCache.copy()`, and trim exist, but there is **no way to branch a running cache into independent executions without copying/recomputing the common prefix** |
| [`#436 "Add cross-request LRU prompt cache (PromptTrie + byte-bounded eviction)"`](https://github.com/ml-explore/mlx-swift-lm/pull/436) | **OPEN** since 2026-07-16 | 0 comments, **1 reaction** | Ports Python `mlx_lm`'s `PromptTrie` + `LRUPromptCache` to Swift, so **a new request sharing a prefix with an *earlier* request reuses it** instead of re-prefilling. Adds `KVCache.nbytes`. **This is precisely the generalization our per-session pool lacks** |
| **New, already-merged cache surface** | on `main` | — | `KVCacheStatus` + `model.cacheStatus(parameters:)` / `container.cacheStatus()` / `session.cacheStatus()` reporting `capacityDisposition` (`.notRequested/.fullyApplied/.partiallyApplied/.unsupported/.ignored`), per-layer `kind`, `capacitySource`, `state`, `resolvedStrategy`, `memoryBytes`; `makePromptCache`, `makePromptCacheWithLayerCount`, `canTrimPromptCache`, `trimPromptCache`, `savePromptCache`/`loadPromptCache` (safetensors + metadata); `makeAttentionKVCache(parameters:)` / `makeHybridAttentionKVCache(...)` for `newCache` overrides; `#639 "Report KV cache memory in KVCacheStatus"` and `#640` merged, `#550 "Fix compiled decoding with fixed-capacity KV cache"` open |

**Verdicts:** ADOPT `cacheStatus`/`KVCacheStatus` + `savePromptCache`/`loadPromptCache` + `make*KVCache` helpers (all on `main`, all upstream). **VENDOR/WATCH #436** if we want cross-session (not just cross-turn) prefix reuse — but vendor it as a patch we intend to upstream, not a permanent fork. WATCH #629 for true CoW branching. **DON'T** build our own KV quantization.

### 5.5 Multimodal embedders (vision / audio towers)

| Item | State | What it does | Verdict |
|---|---|---|---|
| [`#684 Add EmbeddingGemma 2 full support`](https://github.com/ml-explore/mlx-swift-lm/pull/684) | OPEN, 9 comments, 2 reactions | Text + image + video + audio in one space, interleavable; reuses `Gemma4VisionModel` / `Gemma4AudioModel` / `Gemma4MultimodalEmbedder` from `MLXLMCommon/Models/Gemma4Encoders.swift` | **The thing to adopt for multimodal embeddings.** Vendor the branch now, track the merge |
| [`#682 "A shared core for model code & and multimodal input for embedders"`](https://github.com/ml-explore/mlx-swift-lm/issues/682) | OPEN, 9 comments | Proposes deduplicating MLXLLM/MLXVLM/MLXEmbedders copies of shared layers into `MLXLMCommon` (package visibility) and adding an **`MLXMediaEncoders`** target on top of it. Cites concrete drift: *"the embedder copy of Qwen3 never got the newer RoPE and attention helpers from MLXLLM, and a mask bug in EmbeddingGemma sits in code that MLXLLM already has"* — i.e. **#638/#654 would not have happened if this had been done** | WATCH — it is a maintainer-blessed architecture direction (`davidkoski`: *"My first thought is something like `MLXMediaEncoders` that sits on top of `MLXLMCommon`"*). Do not build competing encoder abstractions |
| [`#665 "Add Qwen3-VL text and image embeddings"`](https://github.com/ml-explore/mlx-swift-lm/pull/665) | OPEN (2026-10-02) | `Qwen3VLEmbedding` in `MLXVLM`: normalized text, image, and mixed-input vectors; terminal-token pooling; batches one item at a time; rejects context overflow | WATCH |
| [`#686 "MLXEmbedders: add ModernBERT (Granite Embedding R2) support"`](https://github.com/ml-explore/mlx-swift-lm/issues/686) | OPEN (2026-10-08), 3 comments | `modernbert` / `ibm-granite/granite-embedding-97m-m…` | WATCH |
| Gemma 4 audio/video: [`#343` (closed) "Gemma 4: add audio and video multimodal support"](https://github.com/ml-explore/mlx-swift-lm/issues/343), [`#194 "Add Gemma 3n E4B audio encoder (Conformer) support"`](https://github.com/ml-explore/mlx-swift-lm/issues/194) (open, 8 comments), [`#207 "Feature Request: Add Support for Multimodal Gemma 4 Audio Encoder & Preprocessing"`](https://github.com/ml-explore/mlx-swift-lm/issues/207) (5 comments) | mixed | Audio towers are the least-covered modality | WATCH |
| Rerankers: [`#673`](https://github.com/ml-explore/mlx-swift-lm/issues/673) / [`#676 "Implement reranker protocols (Qwen variations)"`](https://github.com/ml-explore/mlx-swift-lm/pull/676) | OPEN | Family-specific prompts/scoring for Zerank-2, ContextualAI, Jina v3.5 | WATCH — our reranker needs will be met upstream |

### 5.6 Dynamic model registry / plugin pattern — **already exists, adopt it**

This is the answer to *"any dynamic model registry / plugin pattern that would let us support new architectures without patching the app"*:

| Piece | File | API | Type |
|---|---|---|---|
| Type registry | `Libraries/MLXLMCommon/Registries/ModelTypeRegistry.swift` | `public actor ModelTypeRegistry<T>`: `registerModelType(_:creator:)`, **`registerModelType(_:matches:creator:)`** (predicate for ambiguous `model_type` strings shared by multiple targets), `createModel(configuration:modelType:)`, **`contains(_:)`** — *"Lets a caller check support without attempting a (throwing, allocating) `createModel`, e.g. to decide **before a multi-GB download** whether a Hub repo's `model_type` is runnable"* | Public |
| Model-config registry | `Registries/AbstractModelRegistry.swift` | `register(configurations: [ModelConfiguration])`, `configuration(id:)` (returns a synthesized `ModelConfiguration(id:)` when unknown — never throws), `contains(id:)`, `models` | Public, `@unchecked Sendable`, `NSLock`-guarded |
| Per-family registries | `LLMTypeRegistry`/`LLMRegistry` (MLXLLM), `VLMTypeRegistry`/`VLMRegistry` (MLXVLM), `EmbedderTypeRegistry`/`EmbedderRegistry` (MLXEmbedders), `MTPDrafterModelFactory`, `RerankerModelFactory` | `.shared` singletons, all backed by the two above | Public |
| Adjacent registries | `ChatConventionsRegistry`, `ModelAdapterTypeRegistry`, `ProcessorTypeRegistry`, `VLMProcessorLoadingRegistry` | — | Public |

**What this buys us:** we can register a *new architecture* (or override an existing `model_type`) at app start-up from our own module, with our own creator closure, and then let upstream's `ModelContainer`/`ChatSession`/`EmbedderModelContainer` do all the loading. **We should not fork `mlx-swift-lm` to add a model.** We should ship a small `OurAppModelPlugins` module that calls `LLMTypeRegistry.shared.registerModelType(...)` / `EmbedderTypeRegistry.shared.registerModelType(...)` / `EmbedderRegistry.shared.register(configurations: [...])`.

Also worth adopting for our pipeline rather than hand-rolling:
- **`MLXGuidedGeneration`** — grammar-constrained generation from JSON Schema or EBNF (upstream alternative to our tool-call enforcement; `MLXCXGrammar`/xgrammar underneath).
- **`MLXScriptedLM`** — scripted tokenizers and models for tests without weights. Our CI currently needs multi-GB downloads; this removes that.
- **`MLXRerankers`** — cross-encoder reranking, i.e. hybrid retrieval without a second embedding stack.
- **Wired-memory admission control** — see §8; this is the biggest "we were about to build this" item.
- **`#551` "Report the progress of reading the weights while loading a model"** (open) — would close the gap in our downloader UX between "downloaded" and "ready".
- **`#648 "Next Release"`** — the release-planning issue to watch for the next tag.

---

## 6. Alternatives to MLX Swift for the same jobs

### 6.1 Text generation

| Option | Repo / evidence | iOS reality | When it is the right tool |
|---|---|---|---|
| **MLX Swift** (`MLXLLM` + `MLXLMCommon`) | `mlx-swift-lm`, 834★, 180 commits/90d, `3.32.3` | GPU-only, no ANE, no Simulator, iOS 17+. Best open-weight breadth (Qwen3.5, Gemma 4, LFM2.5, MoE + hybrid SSM), native tool calling, MTP/speculative work in flight | **Our chat engine. Keep it.** |
| **Core ML** | `MLModel`, iOS 11+; docs note *"Use an `MLModel` instance on one thread or one dispatch queue at a time"* | CPU+GPU+ANE. Production-supported, Simulator-friendly, but you must ship a converted asset per model | Right tool when we need ONE fixed model at max efficiency/ANE, or a tiny model that must work in the Simulator |
| **Core AI** (new, Apple) | https://developer.apple.com/core-ai/ | *"modern, memory-safe Swift API … ahead-of-time compilation … fine-grained control over inference memory, zero-copy data paths, stateful execution … iPhone, iPad, Mac, Apple Vision Pro"* | The likely long-term Apple production path. **Watch.** Re-evaluate when our OS floor rises and Core AI model coverage is public |
| **Foundation Models** (Apple) | https://developer.apple.com/foundation-models-framework/ | Apple's built-in on-device model, iOS 26+; zero download | Zero-friction fallback/Tier-0 model. And note `MLXFoundationModels` (iOS 27 SDK) lets our MLX models *appear as* `LanguageModel`s — best of both |
| **llama.cpp / GGUF** | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp), 130,947★, v0.6.0 (2026-10-05), 2,551 open issues | CPU + partial Metal; no ANE; Simulator-friendly; huge GGUF catalogue (incl. uncensored builds users ask for) | Right tool if we must accept arbitrary community GGUFs, or want a CPU fallback path. `tattn/LocalLLMClient` (219★) is the reference Swift abstraction over both |
| **ExecuTorch** | [pytorch/executorch](https://github.com/pytorch/executorch), 5,089★, v1.5.1 (2026-09-23), **1,300 open issues** | Exists for iOS; adds a whole PyTorch export toolchain | Not for us |
| **ONNX Runtime** | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime), 22,056★, v1.31.0 (2026-10-09), 1,773 open issues | iOS supported; CoreML EP exists but no ANE-native LLM story | Not for us |
| **LiteRT** | [google-ai-edge/LiteRT](https://github.com/google-ai-edge/LiteRT), 3,488★, v2.3.0 (2026-10-07), **3,054 open issues** | Google's official iOS path (see Google AI Edge Gallery) | Only if we specifically want Gemma-family parity with Google's app |
| **transformers.js in a WebView** | — | WASM/WebGPU in Safari; no persistent model residency, no Metal kernel control, memory duplicated with the WebView | Not for us |

### 6.2 Text embeddings

| Option | Evidence | Fit |
|---|---|---|
| **`MLXEmbedders` (upstream)** | `mlx-swift-lm`, first-party library; 8 `model_type`s registered; pooling strategies; catalogue of 15+ models; rerankers; #684 adds embeddinggemma-2 | ✅ **Use this.** Same runtime, same memory model, same container/admission patterns we already built |
| **Core ML / `MLTensor` — `swift-embeddings`** | [jkrukowski/swift-embeddings](https://github.com/jkrukowski/swift-embeddings), 155★, `0.1.1` (2026-09-21), 6 open issues, MIT, last push 2026-09-21. *"Run embedding models locally in Swift using `MLTensor`."* Supports BERT, **ModernBERT**, NomicBERT, RoBERTa, XLM-RoBERTa with `LoadConfig` weight-key transforms | ⚠️ **Complementary, not a replacement.** It is the right tool if we want an ANE-eligible embedder *and* a Simulator-friendly path, or models MLX has not ported (ModernBERT/Granite). Different tensor runtime from our chat path — extra resident memory. Keep in the "watch/adopt for specific models" bucket |
| **Apple `NLContextualEmbedding`** | `NaturalLanguage`, iOS 17.0+ (docs cached 2026-10-12). *"dense vector representation … using models trained with contextualized language understanding"*; assets via `requestAssets`; per-language models | ✅ **Free, zero-download, ANE-friendly, and already integrated** by `VecturaKit`'s `NLContextualEmbedder`. Best choice for a default/fallback embedder and for locale coverage we can't ship weights for. Quality below a tuned 300M model, but zero cost and zero memory |
| **llama.cpp / GGUF embeddings** | Same wrappers | Only for parity with a GGUF chat stack |
| **`mlx-embeddings` (Python)** | [Blaizzy/mlx-embeddings](https://github.com/Blaizzy/mlx-embeddings), 449★, `v0.1.0` (2026-03-24), last push **2026-05-13**, 31 open issues | Reference only — `MLXEmbedders` is ported from `taylorai/mlx_embedding_models` + this |
| **`swift-gguf`** | [jkrukowski/swift-gguf](https://github.com/jkrukowski/swift-gguf), 1★, last push 2026-03-29 | Irrelevant |

### 6.3 Image / audio embeddings

| Option | Evidence | Fit |
|---|---|---|
| **`EmbeddingGemma 2` via `MLXEmbedders` (#684)** | One space for text + image + video + audio, interleavable; parity 0.9999 vs Transformers SDPA; text-only footprint ~391 MB peak on iPhone 14 Pro; 288 MB vs 1.23 GB with component loading | ✅ **Primary choice.** It is literally a combined text/image/audio embedder, and #580's component loading keeps the media towers off-heap until first use |
| **Vision framework feature prints** | `VNGenerateImageFeaturePrintRequest` | ⚠️ Hand-rolled alternative for image-only similarity: zero download, fast, ANE-friendly, but a *different* vector space from our text embeddings — so it cannot serve cross-modal retrieval. Useful only for "find similar images in this library" |
| **CLIP-family on Core ML / ONNX** | Widely available converted models | ⚠️ Only if we need text↔image and cannot ship EmbeddingGemma 2 |
| **Audio** | No first-party ANE audio-embedding path; Speech framework is transcription, not embeddings; Gemma 3n E4B audio encoder is an open request (#194) | ⚠️ EmbeddingGemma 2's audio tower is the only credible on-device option in our stack today |

### 6.4 Decision

| Job | Decision |
|---|---|
| **Chat / text generation** | **MLX Swift** (`MLXLLM` + `MLXLMCommon`). Keep. Add `FoundationModels` (iOS 26+) as a zero-download Tier-0, and plan for `MLXFoundationModels` when our OS floor hits 27. |
| **Text embeddings** | **`MLXEmbedders` (upstream)** as the primary engine; **`NLContextualEmbedding`** as the zero-cost fallback; **`swift-embeddings`** only for specific architectures MLX has not ported (ModernBERT/Granite) and only if the extra runtime is justified. |
| **Image/audio (multimodal) embeddings** | **`EmbeddingGemma 2` via `MLXEmbedders` (#684 + #580)**, with `Vision` feature prints as the narrow image-only fallback. |
| **Vector store** | Don't build one. Evaluate **[VecturaKit](https://github.com/rryam/VecturaKit)** (324★, `6.3.0` 2026-08-05, 2 open issues, iOS 18+/macOS 15+/watchOS 11+/tvOS 18+/visionOS 2+) — hybrid BM25+vector search, pluggable embedders including an `MLXEmbedder`, auto dimension detection; or **[sqlite-vec](https://github.com/asg017/sqlite-vec)** (8,183★, `v0.1.9` 2026-03-31, 215 open issues) if we want vectors inside the SQLite we already have. |

---

## 7. Reception + maturity table

Star/issue/commit numbers fetched from the GitHub REST API on **2026-10-12**. "Commits /90d" is the last-page count of `GET /commits?since=2026-07-14`.

| Project | What | Latest tag (date) | Commits /90d | Open issues (total / excl. PRs) | Stars | Verdict |
|---|---|---|---|---|---|---|
| [`ml-explore/mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) | First-party Swift library: LLM/VLM/embedder/reranker/FoundationModels bridge | `3.32.3` (2026-09-30) | **180** | 104 / **69** (35 open PRs; 463 closed PRs) | 834 | **ADOPT** — but pin deliberately and track `main`; read `skills/mlx-swift-lm/references/*` before writing any new model/embedding code |
| [`ml-explore/mlx-swift`](https://github.com/ml-explore/mlx-swift) | First-party Swift API for MLX + Metal kernels + memory/wired-memory control | `0.32.3` (2026-09-30) | 26 | 62 / 37 | 2,059 | **ADOPT** (we already do). Note open iOS launch bugs #485/#494/#497 |
| [`ml-explore/mlx-swift-examples`](https://github.com/ml-explore/mlx-swift-examples) | Example apps + CLI tools | `2.29.1` (2025-10-16) | **0** (last commit 2026-06-15) | 43 / 32 | 2,676 | **WATCH (read-only)** — reference code, not a dependency; effectively in maintenance freeze |
| [`huggingface/swift-transformers`](https://github.com/huggingface/swift-transformers) | Tokenizers / HF config loading | `1.3.5` (2026-10-09) | 16 | 36 / 17 | 1,361 | **ADOPT** (we already do) |
| [`huggingface/swift-huggingface`](https://github.com/huggingface/swift-huggingface) | HF Hub client + Inference Providers | `1.0.0` (2026-10-09) | 36 (7 releases/90d) | 5 | 178 | **ADOPT**, but read the 1.0.0 breaking-change notes (`swift-xet` 1.0 floor, `HTTPClientError` now a struct with `.code`, `Provider`/`Capability` now structs) |
| [`jkrukowski/swift-embeddings`](https://github.com/jkrukowski/swift-embeddings) | `MLTensor`-based embedder models (BERT/ModernBERT/NomicBERT/RoBERTa/XLM-R) | `0.1.1` (2026-09-21) | — | 6 | 155 | **WATCH** — adopt only for architectures MLX lacks |
| [`rryam/VecturaKit`](https://github.com/rryam/VecturaKit) | On-device vector DB, hybrid BM25+vector, pluggable embedders incl. MLX | `6.3.0` (2026-08-05) | — | 2 | 324 | **ADOPT (evaluate)** — smallest, most iOS-native vector store with a real MLX path |
| [`asg017/sqlite-vec`](https://github.com/asg017/sqlite-vec) | Vector search SQLite extension | `v0.1.9` (2026-03-31) | — | 215 | 8,183 | **WATCH** — 7 months without a release; use if we want vectors in existing SQLite |
| [`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp) | GGUF inference engine + iOS bindings | `v0.6.0` (2026-10-05) | — | **2,551** | **130,947** | **ADOPT only if we need arbitrary GGUFs.** Massive, healthy, but a second runtime with a second memory footprint |
| [`pytorch/executorch`](https://github.com/pytorch/executorch) | PyTorch on-device runtime | `v1.5.1` (2026-09-23) | — | **1,300** | 5,089 | **AVOID** for our use case (toolchain cost, no advantage over MLX here) |
| [`microsoft/onnxruntime`](https://github.com/microsoft/onnxruntime) | Cross-platform inference runtime | `v1.31.0` (2026-10-09) | — | 1,773 | 22,056 | **AVOID** for iOS LLM/embeddings (no ANE-native generative path) |
| [`google-ai-edge/LiteRT`](https://github.com/google-ai-edge/LiteRT) | Google's on-device runtime (TFLite successor) | `v2.3.0` (2026-10-07) | — | **3,054** | 3,488 | **AVOID** unless we want Gemma parity with Google's own app |
| [`ShenghaiWang/SwiftLlama`](https://github.com/ShenghaiWang/SwiftLlama) | Thin Swift wrapper over llama.cpp | — | — | 2 | 99 | **AVOID** — last push **2025-08-26**, 13 months stale |
| [`mattt/llama.swift`](https://github.com/mattt/llama.swift) | Semantically-versioned llama.cpp access for Swift | — | — | — | 83 | **WATCH** — last push 2026-10-12, actively maintained; the modern choice if we ever need GGUF |
| [`guinmoon/llmfarm_core.swift`](https://github.com/guinmoon/llmfarm_core.swift) | llama/GGML core extracted from LLM Farm | — | — | — | 283 | **WATCH** — last push 2025-12-09; app delisted from the App Store |
| [`Blaizzy/mlx-embeddings`](https://github.com/Blaizzy/mlx-embeddings) (Python) | Reference MLX embedding models | `v0.1.0` (2026-03-24) | — | 31 | 449 | **REFERENCE ONLY** — last push 2026-05-13; MLXEmbedders already ported the useful parts |
| [`Blaizzy/mlx-vlm`](https://github.com/Blaizzy/mlx-vlm) (Python) | Reference MLX VLM inference/fine-tuning | `v0.7.6` (2026-10-05) | — | 225 | 5,614 | **REFERENCE ONLY** — active, useful for porting new VLMs/encoders |
| [`ml-explore/mlx-lm`](https://github.com/ml-explore/mlx-lm) (Python) | First-party Python LLM/VLM runner (`PromptTrie`/`LRUPromptCache` live here) | `v0.31.3` (2026-04-22) | — | 230 | 7,275 | **REFERENCE** — source of truth for caching/serving semantics we port to Swift |
| [`taylorai/mlx_embedding_models`](https://github.com/taylorai/mlx_embedding_models) (Python) | Original MLX embedder ports | — | — | 6 | 98 | **AVOID** — stale since 2024-09-27; superseded by `MLXEmbedders` |

---

## 8. Recommendation

### 8.1 ADOPT THIS NOW (upstream already solves it — do not hand-roll)

| # | Adopt | Why | Link / API |
|---|---|---|---|
| 1 | **Bump `mlx-swift-lm` past 2026-10-07** (next tag, or a pinned commit ≥ `#654`'s merge) | Our `3.32.3` pin **(2026-09-30) predates the EmbeddingGemma bidirectional-attention fix (2026-10-07)**. Today any EmbeddingGemma embedding we compute is causally-masked garbage (cosine 0.45–0.70 vs reference). This is a correctness bug, not a nicety | [`#654`](https://github.com/ml-explore/mlx-swift-lm/pull/654) (merged), [`#638`](https://github.com/ml-explore/mlx-swift-lm/issues/638) |
| 2 | **`MLXEmbedders` as the embedding engine** | First-party, maintained (180 commits/90d), a two-level registry, 8 `model_type`s, 6 pooling strategies, a 15-model catalogue, and reranker support — all of which we were about to write | `EmbedderModelFactory.shared.loadContainer(from:using:configuration:)`, `EmbedderModelContainer.perform`, `context.pooling(_:mask:normalize:applyLayerNorm:)` |
| 3 | **`ModelTypeRegistry` / `AbstractModelRegistry` as our plugin mechanism** | Register new architectures and whole model configs from our own module. `contains(_:)` even lets us validate a Hub repo's `model_type` **before** a multi-GB download | `LLMTypeRegistry.shared.registerModelType(_:matches:creator:)`, `EmbedderTypeRegistry.shared.registerModelType(...)`, `EmbedderRegistry.shared.register(configurations:)` |
| 4 | **`WiredMemoryManager` / `WiredMemoryTicket` + `WiredSumPolicy` + `canAdmit`** | **This is our "admission control" — upstream already built it, with reservation vs active tickets, per-policy grouping, hysteresis, and a concurrency gate that suspends `start()` until capacity frees. Do not ship our own.** | `Source/MLX/WiredMemory.swift`; `MLXLMCommon/README.md` §"Wired Memory"; `generate(..., wiredMemoryTicket:)` |
| 5 | **`Memory.cacheLimit` / `Memory.memoryLimit` / `Memory.snapshot()` / `Memory.clearCache()`** | Apple's own iOS doc mandates cache-limit tuning; we should expose it as a user-visible "memory budget" and log `snapshot().delta` around model load and generation | `running-on-ios.md`, `Source/MLX/Memory.swift` |
| 6 | **`KVCacheStatus` + `cacheStatus()` for our KV-precision control** | Reports `capacityDisposition`, per-layer `kind`/`capacitySource`/`state`/`memoryBytes`. Replaces guessing with telemetry, and `#639` already added KV memory reporting | `model.cacheStatus(parameters:)`, `container.cacheStatus(parameters:)`, `session.cacheStatus()` |
| 7 | **`savePromptCache` / `loadPromptCache`** | Cross-launch prompt-cache persistence, safetensors + metadata, for free — a straight upgrade to our session pool | `mlx-swift-lm` `KVCache.swift` |
| 8 | **The in-repo agent docs** | `skills/mlx-swift-lm/references/{embeddings,kv-cache,generation,concurrency,model-container}.md` are more accurate and more current than the docc. They already document the `RotatingKVCache.toQuantized()` `fatalError()` trap and the `updateQuantized` requirement | `mlx-swift-lm/skills/`, `mlx-swift/skills/` |
| 9 | **`MLXGuidedGeneration`** for schema-constrained output | Upstream JSON-Schema/EBNF constrained decoding; removes a class of tool-call parsing hacks | `Libraries/MLXGuidedGeneration` |
| 10 | **`MLXScriptedLM`** for CI | Tests without multi-GB downloads | `Libraries/MLXScriptedLM` |
| 11 | **`Memory`-budget-driven model catalogue (pattern, from Private LLM)** | Declare/derive a RAM tier per model and gate the download. The most-copied UX pattern in the category, and cheap | §4.3 |
| 12 | **`NLContextualEmbedding` as a zero-download fallback embedder** | iOS 17+, free, no weights, ANE-friendly; `VecturaKit` already wires it up | `NaturalLanguage` |

### 8.2 VENDOR THIS (real value, not yet merged — pin, patch, and plan to upstream)

| # | Vendor | Status | Rationale |
|---|---|---|---|
| 1 | **EmbeddingGemma 2 support** ([`#684`](https://github.com/ml-explore/mlx-swift-lm/pull/684)) | OPEN, `needs-review`, 9 comments, 2 reactions, updated today | Text + image + video + audio in one embedding space with measured parity (0.9999) and a measured iPhone footprint (391 MB peak text-only). The public/package API shape is still under discussion (`davidkoski`, `CodebyCR`), so it may change before merge — vendor it behind our own thin wrapper so the upstream API shift costs us one file |
| 2 | **Component-aware checkpoint / on-demand loading** ([`#580`](https://github.com/ml-explore/mlx-swift-lm/pull/580), merged 2026-10-12; predecessor [`#679`](https://github.com/ml-explore/mlx-swift-lm/pull/679), merged 2026-10-05) | **Merged today** | Merged but unreleased; it is what makes "288 MB vs 1.23 GB" possible for text-only EmbeddingGemma-2. Take it from `main` behind the same wrapper as #684 |
| 3 | **Cross-request LRU prompt cache** ([`#436`](https://github.com/ml-explore/mlx-swift-lm/pull/436), `PromptTrie` + byte-bounded eviction + `KVCache.nbytes`) | OPEN since 2026-07-16, 1 reaction | Our session pool only reuses prefixes *within* a session. This adds cross-request reuse — the same thing Python `mlx_lm`'s server has. Vendor if the pool is a product differentiator; be ready to upstream |
| 4 | **Read-progress during weight loading** ([`#551`](https://github.com/ml-explore/mlx-swift-lm/pull/551)) | OPEN | Closes the dead zone between "download complete" and "model ready" in our downloader UX |
| 5 | **Prefix-rewind correctness in rotating caches** ([`#622`](https://github.com/ml-explore/mlx-swift-lm/pull/622); see [`#424`](https://github.com/ml-explore/mlx-swift-lm/issues/424), [`#618`](https://github.com/ml-explore/mlx-swift-lm/issues/618)) | OPEN | If we use `maxKVSize` at all, our prefix reuse can silently no-op once the window wraps. Either vendor the fix or avoid wrapping caches with the session pool |

### 8.3 WATCH (do not build; re-evaluate at each upstream tag)

| # | Watch | Signal to watch for |
|---|---|---|
| 1 | **`MLXMediaEncoders` / shared-core refactor** ([`#682`](https://github.com/ml-explore/mlx-swift-lm/issues/682)) | A maintainer-endorsed direction (`davidkoski`). When it lands, our multimodal embedder wiring gets simpler. Do not build a competing encoder abstraction now |
| 2 | **Multimodal embedder siblings**: [`#665` Qwen3-VL embeddings](https://github.com/ml-explore/mlx-swift-lm/pull/665), [`#686` ModernBERT/Granite](https://github.com/ml-explore/mlx-swift-lm/issues/686) | Which `model_type` set the embedder registry converges on |
| 3 | **Branchable/CoW KV cache** ([`#629`](https://github.com/ml-explore/mlx-swift-lm/issues/629)) | True multi-session prefix sharing without copies |
| 4 | **Bounded prompt-lookup decoding** ([`#643`](https://github.com/ml-explore/mlx-swift-lm/pull/643), [`#426`](https://github.com/ml-explore/mlx-swift-lm/issues/426)) | **Draft-model-free** speedup — the only speculative-decoding flavour that is affordable under a jetsam budget |
| 5 | **Qwen3.5/3.8 MTP** ([`#545`](https://github.com/ml-explore/mlx-swift-lm/pull/545), [`#581`](https://github.com/ml-explore/mlx-swift-lm/pull/581), [`#279`](https://github.com/ml-explore/mlx-swift-lm/issues/279)) | Correctness caveats are still open (`#459`, `#542` closed, `#496`) |
| 6 | **TurboQuant / rotating quantized KV** ([`#294`](https://github.com/ml-explore/mlx-swift-lm/issues/294)) | Whether the `RNT56` fork gets upstreamed |
| 7 | **`MLXFoundationModels`** (iOS 27 SDK, `FoundationModelsIntegration` trait) | When iOS 27 becomes our deployment floor, we can expose MLX models through `LanguageModelSession` and inherit Apple's session/UI affordances |
| 8 | **Apple Core AI** | Model coverage + whether it gets an MLX-adjacent path. The strategic alternative if MLX stalls |
| 9 | **`mlx-swift` iOS bug watch-list**: [#485](https://github.com/ml-explore/mlx-swift/issues/485) (hang before `main()` on device), [#494](https://github.com/ml-explore/mlx-swift/issues/494)/[#497](https://github.com/ml-explore/mlx-swift/issues/497) (launch crashes), [#349](https://github.com/ml-explore/mlx-swift/issues/349)/[#460](https://github.com/ml-explore/mlx-swift/issues/460) (`default.metallib` bundling) | [#460](https://github.com/ml-explore/mlx-swift/issues/460) matters if we ever build via Tuist or run `swift test` |
| 10 | **`swift-huggingface` 1.x API churn** | `Provider`/`Capability` are now structs and `HTTPClientError` a struct with `.code` — our downloader should not exhaustively `switch` on them |
| 11 | **`mlx-swift-examples`** | 0 commits/90d. If it stays frozen, our fork becomes the de-facto reference app |

### 8.4 DON'T

| # | Don't | Why |
|---|---|---|
| 1 | **Write our own embedder model implementations / registry / pooling** | `MLXEmbedders` already has 8 registered architectures, 6 pooling strategies, a 15-model catalogue, and reranker support |
| 2 | **Write our own wired-memory budgeting or admission control** | `WiredMemoryManager` + `WiredSumPolicy`/`WiredMaxPolicy`/`WiredFixedPolicy` + `Ticket.kind` (`.active` vs `.reservation`) + `canAdmit` already implement exactly this, with reservation semantics that keep the limit low when idle |
| 3 | **Fork `mlx-swift-lm` to add a model architecture** | Use `registerModelType` — this is why the registry exists |
| 4 | **Build speculative decoding / MTP myself** | Active, unsettled upstream, with open correctness issues; and drafter models cost resident memory we don't have |
| 5 | **Combine `RotatingKVCache` with `kvBits`** | `RotatingKVCache.toQuantized()` `fatalError()`s; and wrapping caches defeat prefix reuse and speculative rollback ([#424](https://github.com/ml-explore/mlx-swift-lm/issues/424)) |
| 6 | **Trust `kvBits` with externally-held cache references** | Open, year-old issue [`#81`](https://github.com/ml-explore/mlx-swift-lm/issues/81): `maybeQuantizeKVCache` causes a COW so the caller's reference goes stale |
| 7 | **Depend on `mlx-swift-examples`** | 0 commits/90d, last release 2025-10-16, explicitly "examples" — copy patterns, don't link code |
| 8 | **Add ExecuTorch / ONNX Runtime / LiteRT** | A second runtime, a second memory footprint, and no capability MLX lacks for our jobs |
| 9 | **Depend on `SwiftLlama`** | Last push 2025-08-26. Use `mattt/llama.swift` (2026-10-12) if GGUF is ever needed |
| 10 | **Rely on the iOS Simulator for anything touching `MLXArray`** | Apple's own MLX iOS doc says it is impossible — no modern `MTLGPUFamily`. Our CI needs a device (or `Mac (Designed for iPad)`) |
| 11 | **Assume the ANE is in play** | MLX has zero ANE support (code search: 0 hits for "Neural Engine" in `ml-explore/mlx`); the M5 "Neural Accelerators" it targets are **GPU** units, OS-gated to 26.2+ and arch gen ≥17/18 |

### 8.5 Things where a community solution already does exactly what we were about to hand-roll — explicitly flagged

| We were about to build | Already exists | Where |
|---|---|---|
| An embedder registry + model-config catalogue | `EmbedderTypeRegistry` (8 types, predicate-based overload) + `EmbedderRegistry` (15+ models) | `mlx-swift-lm/Libraries/MLXEmbedders/ModelFactory.swift` |
| Pooling (mean/cls/last/max) with sentence-transformers config parsing | `Pooling` + `PoolingConfiguration` + `context.pooling(...)` | `MLXEmbedders/Pooling.swift` |
| A dynamic/plugin model registry so new architectures don't require app patches | `public actor ModelTypeRegistry<T>` with `registerModelType(_:matches:creator:)` and `contains(_:)` | `MLXLMCommon/Registries/ModelTypeRegistry.swift` |
| Memory budgeting + admission control for a single resident model | `WiredMemoryManager` / `WiredMemoryTicket` / `WiredSumPolicy.canAdmit` / `kind: .reservation` | `mlx-swift/Source/MLX/WiredMemory.swift`; `MLXLMCommon` README |
| KV-cache telemetry / "what's actually resident" | `KVCacheStatus`, `cacheStatus(parameters:)`, `capacityDisposition`, per-layer `memoryBytes` | `MLXLMCommon` (`#639` merged) |
| Prompt-cache persistence across launches | `savePromptCache` / `loadPromptCache` (safetensors + metadata) | `MLXLMCommon/KVCache.swift` |
| Cross-request prefix reuse (an LRU prompt cache) | `PromptTrie` + byte-bounded eviction (`#436`) — same design as Python `mlx_lm` | PR [`#436`](https://github.com/ml-explore/mlx-swift-lm/pull/436) |
| On-demand component loading to keep unused towers out of memory | `#580` + `#679` (merged) | PRs [`#580`](https://github.com/ml-explore/mlx-swift-lm/pull/580), [`#679`](https://github.com/ml-explore/mlx-swift-lm/pull/679) |
| Grammar-constrained / JSON-Schema-constrained output | `MLXGuidedGeneration` (+ `MLXCXGrammar`) | `Libraries/MLXGuidedGeneration` |
| Test doubles for models/tokenizers without weights | `MLXScriptedLM` | `Libraries/MLXScriptedLM` |
| An on-device vector store with hybrid search | `VecturaKit` (hybrid BM25+vector, pluggable embedders incl. MLX), or `sqlite-vec` in existing SQLite | [rryam/VecturaKit](https://github.com/rryam/VecturaKit), [asg017/sqlite-vec](https://github.com/asg017/sqlite-vec) |
| A zero-cost embedder for the "no model installed" case | `NLContextualEmbedding` (`NaturalLanguage`, iOS 17+), with zero weight downloads | Apple docs; `VecturaKit`'s `NLContextualEmbedder` |
| A cross-runtime provider abstraction for local models | `tattn/LocalLLMClient` (219★, llama.cpp **and** MLX behind one Swift API) | [tattn/LocalLLMClient](https://github.com/tattn/LocalLLMClient) |

---

## Appendix A — URL index

Core: https://github.com/ml-explore · https://github.com/ml-explore/mlx · https://github.com/ml-explore/mlx-swift · https://github.com/ml-explore/mlx-swift-lm · https://github.com/ml-explore/mlx-swift-examples · https://github.com/ml-explore/mlx-lm · https://mlx-framework.org/ · https://mlx-explore.github.io/mlx-swift/
Apple: https://developer.apple.com/machine-learning/ · https://developer.apple.com/core-ai/ · https://developer.apple.com/documentation/coreai · https://developer.apple.com/foundation-models-framework/ · https://developer.apple.com/documentation/coreml · https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding · https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports · https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_developer_kernel_increased-memory-limit · https://developer.apple.com/documentation/metal/mtlgpufamily
WWDC: https://developer.apple.com/videos/play/wwdc2026/232/ (Mac agentic MLX) · https://developer.apple.com/videos/play/wwdc2026/233/ (distributed MLX) · https://developer.apple.com/videos/play/wwdc2026/328/ (numerical Swift+MLX) · https://developer.apple.com/videos/play/wwdc2025/298/ · https://developer.apple.com/videos/play/wwdc2025/315/ · https://developer.apple.com/videos/all-videos/?q=MLX
Upstream source read for this report: `mlx-swift-lm` `Package.swift`, `Libraries/MLXEmbedders/{ModelFactory,Pooling,Reranker}.swift`, `Libraries/MLXLMCommon/Registries/{ModelTypeRegistry,AbstractModelRegistry}.swift`, `Libraries/MLXLMCommon/PromptCacheReusePolicy.swift`, `Libraries/MLXLMCommon/README.md`, `skills/{mlx-swift,mlx-swift-lm}/references/*.md`, `mlx-swift` `Source/MLX/{Memory,GPU+Metal,WiredMemory}.swift`, `Source/MLX/Documentation.docc/Articles/{running-on-ios,unified-memory,wired-memory}.md`, `mlx` `mlx/backend/metal/device.cpp`.

## Appendix B — caveats

- All star/fork/issue/commit numbers are point-in-time (2026-10-12) from the GitHub API.
- Third-party market and device-performance claims (modelfit.io RAM tiers and tok/s, per-process jetsam ceilings) are marked **[unverified]** and should be re-measured on our target devices before being used in product decisions.
- No literal "not for production" statement exists in the `ml-explore` org; the "examples vs libraries" split and Apple's Mac-framing of MLX are the real signals, and both are cited in §1.1 and §2.
- `mlx-swift-examples` is frozen (0 commits/90d); if that persists, our fork becomes the de-facto reference MLX iOS app.
