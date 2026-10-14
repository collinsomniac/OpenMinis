# On-device inference in Nabla — implementation and citations

Everything here was verified against the actual sources rather than remembered: the MLX package at
`ml-explore/mlx-swift-lm` **tag 3.32.3** (fetched file by file), the two checkpoints' own `config.json` /
`generation_config.json` / weight index from the Hub API, and this device's reports. Where a claim comes
from a measurement, the measurement is named.

---

## 1. Shape of the subsystem

```
                 Settings → Local Inference
                        │                     Add Provider → On-Device (MLX)
                        ▼                                    │
   LocalModelCatalog ──inspect──► Hub API (files + sizes)     │
        │  confirm                                            ▼
        ▼                                          ProviderType.localMLX
   LocalModelDownloader ──background URLSession──►            │  (a real instance, real entries)
        │  staging → library                                  ▼
        ▼                                    fetchModelsForInstance → LLMModel.allLocalMLX
   LocalModelStore (capabilities, folder)                      │
        │                                                      ▼
        └────────────────► LocalModelHost (actor) ◄──── LocalMLXProvider / LocalMLXAgentProvider
                                 │  one resident model, admission control
                                 ▼
                      MLX: MLXLLM / MLXVLM · ChatSession · KVCache
```

## 2. The MLX API actually used (3.32.3), and why

| call | source location | note |
|---|---|---|
| `LLMModelFactory.shared.loadContainer(from:using:)` | `Libraries/MLXLLM/LLMModelFactory.swift` | text models |
| `VLMModelFactory.shared.loadContainer(from:using:)` | `Libraries/MLXVLM/VLMModelFactory.swift` (type registry: `paligemma, qwen2_vl, qwen2_5_vl, qwen3_vl, qwen3_vl_moe, qwen3_5, qwen3_5_moe, idefics3, gemma3, gemma4, smolvlm, fastvlm, llava_qwen2, pixtral, mistral3, lfm2_vl, glm_ocr, muse_glimmer`) | **required for a vision checkpoint** |
| `#huggingFaceTokenizerLoader()`, `#hubDownloader()` | `Libraries/MLXHuggingFace/Macros.swift` | macros — hence CI's `-skipMacroValidation` |
| `ChatSession(_:instructions:history:generateParameters:additionalContext:tools:toolDispatch:)` | `Libraries/MLXLMCommon/ChatSession.swift` | `additionalContext: ["enable_thinking": Bool]` is how the reasoning switch reaches the template |
| `session.streamDetails(to: [Chat.Message])` | same | accepts a **batch of messages**, which is what makes append-only continuation possible |
| `Chat.Message.user(_:images:)`, `UserInput.Image.ciImage(_:)` | `Chat.swift`, `UserInput.swift` | images reach the model as pixels |
| `Generation.chunk` / `.info` | `Libraries/MLXLMCommon/Evaluate.swift` | `GenerateCompletionInfo` carries `promptTokenCount, generationTokenCount, promptTime, generateTime, totalPromptTokenCount` — the metrics readout is these fields, not an estimate |
| `GenerateParameters(temperature:topP:topK:minP:repetitionPenalty:)` | same | see §4 |
| `KVCache.copy()` / `trim(_:)` / `isTrimmable` | `Libraries/MLXLMCommon/KVCache.swift` | not used directly (ChatSession owns the cache), but this is the mechanism its reuse policy is built on |
| `MTPDrafterModelFactory`, `Qwen35TextMTPRegistration` | `Libraries/MLXLMCommon/MTPDrafterModelFactory.swift`, `Libraries/MLXLLM/Qwen35TextMTPRegistration.swift` | Qwen3.5 native MTP draft support **exists** — unusable for the checkpoint in the library (see §6) |

## 3. Residency and the memory budget

`LocalModelHost` is an `actor` owning **one** `ModelContainer`. `load(id)`:

1. **releases the previous model first** (`unload()` → drop session → drop container → `Memory.clearCache()`),
   then measures — otherwise the check is against memory about to be freed and every second load is
   refused;
2. `need = weights × 1.35`, `have = os_proc_available_memory()`; `need > have` throws
   `LocalModelError.outOfMemory` naming both numbers and suggesting a 4-bit build;
3. `Memory.cacheLimit = 64 MB` (LoopLab's measured-good value — a large pool is not a speed win and is
   memory the KV cache may need);
4. loads through `VLMModelFactory` when the checkpoint declares vision, `LLMModelFactory` otherwise.

Why 1.35 and why an admission check at all: the jetsam ceiling is ~6.4 GB (measured 6.46 GB in
`JetsamEvent-2026-10-11-122523`), the largest model here is 5.16 GB of weights, and an unbudgeted load is
not a slow path — it is process death. Allowing the engine to be killed is worse than a refusal, because
a refusal can explain itself.

Per-model memory-fit is also shown in the UI *before* a download (`LocalInferenceModel.fit`), using the
same formula, so a model that will never run is not downloaded twice.

## 4. Sampling — the largest single speed fix

`Evaluate.swift :: GenerateParameters.sampler()`:

```swift
if temperature == 0 { return ArgMaxSampler() }
else if usesTopP || usesTopK || usesMinP { return TopPSampler(...) }
else { return CategoricalSampler(...) }
```

and `TopPSampler.applyTopP` is `argSort(logprobs, axis: -1) → takeAlong → exp → cumsum → where → putAlong`
— i.e. **a full-vocabulary sort and scatter per generated token** whenever `0 < topP < 1`. Costs at this
device's vocabulary sizes: 151,936 (Qwen3) / 248,320 (Qwen3.5). `applyTopK` is an O(V) partition and
`applyMinP` a single comparison.

Measured consequence: the same Qwen3-0.6B-4bit on the same device ran **164.5 tok/s** with the library
defaults (`topP 1.0` → `CategoricalSampler`) and ~50 tok/s with our `topP 0.95`. `LocalSampling.sanitized`
therefore reads the checkpoint's own `generation_config.json` and keeps `topP` **only** when neither
`topK` nor `minP` is available to do the job more cheaply.

## 5. Prompt-cache reuse

The agent loop re-sends the whole transcript every turn (~6.6k-token system prompt in this app). The
first implementation reused the live `ChatSession` only when the incoming transcript matched what the
session had consumed *exactly* — which in practice failed constantly, so the prompt was re-prefilled.

Now: reuse whenever the incoming transcript is an **extension** of what the session holds (same role, same
text, same image count through the consumed prefix, then any number of new messages), which is the actual
shape of an agent turn. Appending via `streamDetails(to: [newMessages])` is what the API is designed for —
`ChatSession` itself trims its KV cache to the longest common prefix with the new prompt (its
`PromptCachePolicy`, `cachedTokens` ledger in `ChatSession.swift`).

The measured readout reports this directly: **Last turn → "prompt tokens · reused · prefill ms"**.

## 6. Capability detection, and the two facts it surfaced

Read from each checkpoint, never assumed (`LocalModelStore.profile`):

| capability | source |
|---|---|
| vision | `vision_config` in config.json, or a `preprocessor_config.json`, **and** the model_type present in MLXVLM's registry |
| thinking | the chat template (inline `chat_template` or `chat_template.jinja`) mentions `enable_thinking` |
| context | `text_config.max_position_embeddings` |
| sampler | `generation_config.json` |
| weights | the sum of `*.safetensors` in the folder |
| not-a-chat-model | `model_type` prefixes like `whisper`, `stable_diffusion`, `flux` |

Findings for `mlx-community/Qwen3.5-4B-MLX-8bit` (11 files, 5.16 GB):

- **It is a vision model.** Weight index groups include `vision_tower.blocks` (288 tensors),
  `vision_tower.merger`, `patch_embed`, `pos_embed`; config carries
  `vision_config {model_type: qwen3_5, depth: 24, hidden_size: 1024, patch_size: 16, spatial_merge_size: 2,
  out_hidden_size: 2560}`. Loading it through the text factory made the model blind — and the *app's* own
  capability check then told it to use a screenshot tool, which is exactly the `shell_execute` call it
  produced. Declaring `modalityOverride: .vision` is what switches the app to handing over pixels.
- **MTP is declared but not shipped.** `mtp_num_hidden_layers: 1` in the text config, yet the weight index
  contains **no `mtp*` tensors** — the mlx-community conversion drops them. So the Qwen3.5 MTP draft path
  that exists in this MLX version has nothing to draw on; speculative decoding needs a conversion that
  keeps the head.

Architecture reading that explains its speed: 32 layers, of which 24 are `linear_attention` (Gated
DeltaNet-style, `linear_num_key_heads: 16`, `linear_value_heads: 32`, conv kernel 4) and 8 are
`full_attention` (`full_attention_interval: 4`, 4 KV heads, `head_dim: 256`, `attn_output_gate: true`),
vocab 248,320, context 262,144, tied embeddings. Decode is bandwidth-bound: ~4.4 GB read per token at
8-bit ⇒ ~11 tok/s at 56 GB/s; a 4-bit build (~2.6–2.9 GB) ⇒ ~20–25 tok/s, matching the 25.3 tok/s measured
for Qwen3.5-4B 4-bit in LoopLab. **The quantisation choice is the model's speed ceiling; nothing in the
app can beat it.** The 8-bit build also sits at the memory ceiling, which is what made it a crash risk.

Contrast, `mlx-community/Qwen3-0.6B-4bit`: pure attention (`Qwen3ForCausalLM`, 28 layers, 8 KV heads,
`head_dim` 128), vocab 151,936, context 40,960, ~0.35 GB — weights cost so little that the KV cache
dominates long-context decode, which is why reusing the prefill matters most for the small models.

## 7. Thinking traces

Two separate problems, both fixed:

1. The tag literals in the stream splitter had been **mangled into the bare words** (`thinking`, no angle
   brackets), so it matched ordinary prose ("I'm thinking…") and never matched a real tag. They are now
   assembled from parts, so a file write cannot silently strip the brackets again.
2. A thinking-enabled Qwen template **prefills the open tag** into the generation prompt
   (`{{- '<|im_start|>assistant\n' }}{{- ' thinking\n' }}`), so the model's output *starts inside* the
   reasoning block and only the closing tag arrives. The parser therefore begins in the matching state
   instead of waiting for an opening tag that will never come.

`ThinkingLevel.isEnabled` gates it, and the capability flag (`supportsReasoning`) is what makes the app
offer a thinking level at all. Traces go out as `.thinkingDelta`, so they land in the same collapsible
block the cloud providers fill.

## 8. Downloads that survive leaving the app

`LocalModelDownloader` uses `URLSessionConfiguration.background(withIdentifier:)`:
`isDiscretionary = false` (the user asked for it), `sessionSendsLaunchEvents = true`,
`waitsForConnectivity = true`. Each file is a `downloadTask` from
`https://huggingface.co/<repo>/resolve/<full-sha>/<file>` — pinned to the **full commit sha**, because a
moved branch would otherwise change what a half-finished download is fetching. Routing survives relaunch
through `taskDescription` (`repo\u{1F}index`), files move into a staging directory in
`Application Support` and then into the library on completion, and
`AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)` forwards to the
downloader so iOS keeps relaunching us. Completion posts a local notification.

The failure this replaces: `NSURLErrorDomain -1005 "The network connection was lost"` against
`cas-bridge.xethub.hf.co` — a *default* in-process session being suspended. Staying in the app made it
work, which is not something to ask of a 5 GB download.

## 9. What is deliberately not done yet

- **Tool calling for local models.** Schemas are not forwarded, so a local model can only write a tool call
  as text (and the system prompt describes tools it cannot invoke — which is what makes a small model
  imitate the syntax). Native tool calls through MLX's `ToolSpec` + Qwen parser are the right next step;
  this release only ensures the transcript stays faithful and the capability flags are honest.
- **Speculative decoding.** Requires MTP weights (absent from the 4-bit/8-bit conversions here) or a
  draft model small enough not to be a net cost — the earlier LoopLab results were negative for
  draft-model speculation on this hardware.
- **Embeddings/rerankers.** `MLXEmbedders` and `MLXRerankers` ship in the same package; on-device
  embeddings for memory/skills search is the cheapest capability available next.
- **Local ASR / image generation.** Different model families (and, for diffusion, a different package);
  the store labels such checkpoints "not a chat model" rather than pretending.
- **Persisted prefix cache.** The system prompt's KV could be saved and restored across launches
  (`savePromptCache`/`loadPromptCache` exist in `KVCache.swift`); today reuse lives only as long as the
  process.
