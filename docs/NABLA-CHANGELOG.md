# Nabla — changelog

Patch notes for the on-device work in `collinsomniac/OpenMinis` (the OpenMinis fork, rebranded).
Builds are GitHub Actions runs of `.github/workflows/build-ipa.yml`; the number in `openminis-N` is the
run number and becomes `CFBundleVersion`. Installs go over Tailscale with no cable
(`docs/WIRELESS-INSTALL.md`).

Parity note: upstream OpenMinis is left untouched at the same version, installed alongside as
`com.openminis.app`; this fork ships as `io.github.collinsomniac.nabla`.

---

## 26 — "Look before you leap" (2026-10-11)

**The finding of the release: the reported crash was not a crash.** `JetsamEvent-2026-10-11-122523` shows
`proc=Nabla reason=per-process-limit rpages=394230 (~6.46 GB) states=['active','frontmost']` — iOS
terminating the app at its per-process ceiling, with a 5.16 GB model resident and 1.05 GB free.

### Added
- **Memory admission control.** The engine owns one resident model, releases the previous one *before*
  measuring, and refuses a load that cannot fit (`weights × 1.35 ≤ available`), with a message naming the
  shortfall and suggesting a 4-bit build. Refusing loudly, instead of dying silently.
- **Send-time confirmation** when the chosen on-device model is not resident: names the model, names what
  *is* loaded (or "no models loaded"), and asks to load it *for that provider instance*.
- **Capability detection from each checkpoint's own files** — text/vision/unsupported, thinking, context
  length, and sampler defaults. Surfaced as chips in the model list.
- **Vision models loaded as vision models.** Qwen3.5-4B carries a 288-tensor vision tower; it was being
  loaded through the text-only factory, so it could not see an attached photo and instead reached for a
  screenshot tool. Now loaded via `VLMModelFactory`, modality declared `.vision`, images passed as pixels.
- **Background downloads.** A background `URLSession` continues while the app is suspended or terminated,
  with per-file progress, cancel, completion notification and the `AppDelegate` handshake.
- **Measure** (in-app benchmark) and a **Performance** section showing real decode tok/s, prefill time
  and reused tokens per turn.
- **Thinking traces**, parsed correctly, rendered in the collapsible block the cloud providers use.

### Fixed
- **Sampler cost — the single largest speed loss.** The provider set `topP = 0.95`; MLX implements top-p
  with an `argSort` over the entire vocabulary (151,936 for Qwen3, 248,320 for Qwen3.5) plus a scatter,
  *per token*. Measured-good runs used the defaults (`topP 1.0` → `CategoricalSampler`, no sort). Now the
  checkpoint's own `generation_config.json` decides, and `topP` is kept only when no cheaper filter exists.
- **Prompt-cache reuse.** The session was only reused when the transcript matched *exactly*; the agent loop
  re-sends the whole transcript every turn, so in practice the ~6.6k-token system prompt was re-prefilled
  constantly. Reuse now accepts any *extension* of what the session holds.
- **Thinking tag parsing.** The literals had been mangled into the bare words (`thinking`, no angle
  brackets), so the splitter matched ordinary prose and never a tag — and a thinking-enabled Qwen template
  *prefills* the open tag, so the stream begins inside the reasoning block.
- **Buffer cache ceiling** lowered 512 MB → 64 MB (LoopLab's measured-good value; a large pool is not a
  speed win).
- **Dictation panel**: the transcript's box outline removed (it read as a text field, then vanished in
  edit mode); collapse + sparkle/globe moved *below* the text into the mic row; side margins 12 → 20;
  panel height bounded by the keyboard position instead of `screen × 0.6`, which is why long transcripts
  could not be scrolled to the top.
- **Full-screen editor** moved beside the mic/keyboard toggle, so it exists in both input modes.

---

## 23 — "A provider like any other" (2026-10-11)

- **On-device inference became a real `ProviderType.localMLX`**, added through **Add Provider** exactly
  like a vendor. Rationale: a session stores its choice as a *model entry id*, and
  `ProviderConfigStore.entry(for:)` resolves only persisted `config.modelEntries` — so the sentinel
  approach (a synthetic instance, never stored, mirroring the System voice engine) could be listed and
  picked but never resolved. Chat is not voice: voice has its own resolver, chat goes through persisted
  entries everywhere.
- Model list = the library folder, through the standard `fetchModelsForInstance` → `refreshModels` →
  `replaceEntries` path, so show/hide, groups, fallback and the picker all behave.
- Provider detail door: Credential and Base URL sections replaced by **Model library** + **Reload models
  from library**.
- **App-name rebrand of user-visible strings** — curated list, not a blanket substitution (see the
  debugging log: the blanket attempt corrupted container paths and URLs).
- `hasUsableProvider` — one predicate for "can anything serve a request?", replacing
  `!instances.isEmpty` copied into four call sites (which had disabled the send button).

---

## 21 — "Your words are not lost" (2026-10-11)

- **Dictation data-loss bug fixed.** Three separate guards keyed on `isEditingTranscript` discarded
  captured speech: whole VAD segments never reached the buffer, the audio was never sent to ASR, and a
  completed transcription was dropped. The author's intent ("don't let new speech overwrite corrections")
  was fair, but the result path *appends* — it could never overwrite. All three now transcribe and append.
- Pause no longer turns the focal button into a destructive cancel: `showCancelIcon` required
  `isTranscribing && state != .recording`, which made the button a cancel during the `.waiting` window —
  i.e. immediately after the user's own pause tap.
- State-accurate mic labels ("Stop recording" / "Start listening").
- Full-screen transcript editor with character count.

---

## 18 / 21 — "The download that was there all along" (2026-10-11)

- **Model downloads work.** The Hugging Face hub cache stores **symlinks** into a sibling `blobs/`
  directory; a single directory move left every file dangling, so the loader reported `config.json`
  missing for a model that had downloaded perfectly. `adopt` now walks the tree and moves each *resolved*
  file.
- **Check-then-confirm downloads**: one Hub API call returns the file list and per-file sizes, so the
  sheet shows total size, weights, file count, the largest files — and a real memory-fit verdict.
- **Folder picker** for the library (security-scoped bookmark), so models can live anywhere Files can
  reach; **delete**; free-space readout.

---

## 14 / 18 — "Local Inference exists" (2026-10-11)

- New **Settings → Local Inference** page: on-device model library, available memory, whether the
  increased-memory-limit entitlement is *actually granted* (read from the embedded provisioning profile),
  GPU name and working set, thermal state, Apple Intelligence availability.
- MLX SwiftPM dependency added (mlx-swift-lm 3.32.3, mlx-swift 0.32.3, swift-huggingface, swift-transformers;
  products MLXLLM/MLXLMCommon/MLXHuggingFace/MLXVLM/MLX/HuggingFace/Tokenizers).
- CI gained `-skipMacroValidation -skipPackagePluginValidation` (mlx-swift-lm vends
  `MLXHuggingFaceMacros` for `#hubDownloader()` / `#huggingFaceTokenizerLoader()`; a fresh runner has
  trusted nothing).

---

## 9 / 11 — "Nabla" (2026-10-10)

- Fork rebranded into its own app: bundle id `io.github.collinsomniac.nabla`, own app group, own iCloud
  container, `nabla://` scheme, `Nabla.app`, own icon — installs *alongside* App Store Minis.
- **Launch crash fixed**: the signer derives the app group as
  `group.io.github.collinsomniac.nabla.FRJQU6T5U5` (team-id suffix) while the code asked for the
  unprefixed id, so `containerURL(...)` returned nil and a force-unwrap trapped inside
  `SoulStore.load()`. `Shared/AppGroupResolver.swift` now reads the granted group from the embedded
  profile at runtime and falls back to a private container.
- Type-checker timeout in the 8,783-line `ContentView.swift` body resolved by splitting it into staged
  sub-views (`bodyStage1/2/3`).
