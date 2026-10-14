# Debugging log — symptom, evidence, cause, fix

Every entry is a real failure from this project. The **Evidence** line is the thing that identified it —
that is the part worth keeping: several of these were solved *only* because a log, a crash report or the
library's own source was read, and guessing would have produced the wrong fix.

---

## 1. The app "crashed" when sending to a model that was not loaded

- **Symptom** (user): "I had a model selected but not loaded, I sent a message, and the app crashed."
- **Evidence**: no Swift crash report existed for that time. `tools/jetsam_today.py` (new) read the
  device's resource reports over the RSD tunnel and found
  `JetsamEvent-2026-10-11-122523.ips`: `proc=Nabla reason=per-process-limit rpages=394230 (~6.46 GB)
  states=['active','frontmost']`, plus a second at 12:37 (~5.25 GB, suspended). The user's own screenshot
  from 12:24 read **1.05 GB available** with Qwen3.5-4B resident.
- **Cause**: iOS's per-process limit (~6.4 GB with the entitlement). The model is 5.16 GB of weights;
  any further allocation kills the process. Not a logic error — a budget error.
- **Fix**: admission control in `LocalModelHost.load` (`weights × 1.35 ≤ os_proc_available_memory()`,
  checked *after* releasing the previous model), a hard refusal with a readable message, a send-time
  confirmation before a cold load, and a UI memory-fit warning.
- **Lesson**: "it crashed" must be classified before it is fixed. `JetsamEvent` ≠ `.ips` crash.

## 2. Token speed ~50 tok/s where the same model measured 164

- **Symptom** (user): "around maybe 50 tokens a second, if that, with the 0.6 billion parameter Qwen."
- **Evidence**: reading the sampler in the vendored library. `mlx-swift-lm` 3.32.3
  `Libraries/MLXLMCommon/Evaluate.swift` — `GenerateParameters.sampler()` returns `TopPSampler` when
  `topP` is in (0,1), and `TopPSampler.applyTopP` is `argSort(logprobs) → takeAlong → cumsum → where →
  putAlong`: a **full-vocabulary sort per generated token** (151,936 elements for Qwen3; 248,320 for
  Qwen3.5). Our provider set `params.topP = 0.95`. The 164 tok/s runs used `GenerateParameters()`
  defaults → `topP 1.0` → `CategoricalSampler`, which does not sort.
- **Cause**: our own sampling configuration, not the model or the device.
- **Fix**: `LocalSampling.sanitized` takes the checkpoint's `generation_config.json`, keeps `topK`/`minP`
  (O(V) partition / one comparison) and only keeps `topP` when no cheaper filter is available.
- **Lesson**: a per-token cost that looks like a rounding error in a profile is decisive at 150k vocab.

## 3. Download failed with `config.json` missing, for a model that downloaded fine

- **Symptom**: `configurationFileError("config.json", "Models/mlx-community__Qwen3-0.6B-4bit", …)`.
- **Evidence**: LoopLab's known-good `ModelStore.adopt` — it walks the tree and moves each file, calling
  `resolvingSymlinksInPath()`. Compare with ours, which moved the snapshot directory in one `moveItem`.
- **Cause**: the Hugging Face hub cache does not store files in the snapshot directory; it stores
  `models--org--name/blobs/<sha>` plus **symlinks** at `snapshots/<rev>/<file>`. A directory move keeps the
  symlinks and leaves the blobs → every file dangles.
- **Fix**: per-file adopt with symlink resolution, then verify `isModelDir` and remove the half-written
  folder on failure. Later superseded by the background downloader, which writes real files directly.

## 4. Dictation silently discarded minutes of speech

- **Symptom** (user, precisely): dictate → double-tap to edit → start a *second* recording → speak for
  minutes → stop → everything lost.
- **Evidence**: `grep isEditingTranscript` in `Views/Chat/Voice/VoiceInputPanel.swift` found **three**
  guards: `handleSegment` returned before `pendingSegments.append`; `transcribeAudio` returned before the
  request; and the result was dropped by `!self.isEditingTranscript` in the append guard. A long dictation
  arrives as ~5s VAD segments, so every segment was discarded — the loss was continuous, not at the end.
- **Cause**: a blunt version of a legitimate intent ("don't let new speech overwrite corrections"). The
  result path **appends** (`transcript + " " + text`), so it could never overwrite anything.
- **Fix**: all three transcribe and append; the now-unreachable `.droppedWhileEditing` report removed.
- **Lesson**: ask *which* of several guards produced the symptom, and read the append semantics before
  believing a comment about them.

## 5. A blanket string rebrand corrupted the app

- **Symptom**: after replacing `Minis` → `Nabla` inside every string literal, three classes of literal
  were wrong.
- **Evidence**: a `git diff` audit grouped every introduced `Nabla` token by frequency: `NablaImage` ×71,
  `NablaChat` ×57, `OpenNabla` ×21 — container **data paths** (`Library/MinisChat/…`, `MinisImage/`,
  `MinisVideo/`), a real **HTTP-Referer URL** (`github.com/OpenMinis/OpenMinis`), and identifiers/log
  categories (`resolveNablaURL`, `MinisSoulMdChanged`). The regex had also **desynced** on quotes inside
  comments — one `"Minis App"` survived while a neighbouring URL was mangled.
- **Cause**: substring replacement inside a grammatical construct (string literals) that comments can
  break, in a codebase where the word appears inside paths, URLs and keys.
- **Fix**: revert wholesale; redo as `scripts/rebrand_display_strings.py` — a curated list of ~60 exact
  display strings **with expected match counts**, so a miss fails loudly. `scripts/reapply_nabla_edits.py`
  restores the round's non-rebrand edits after such a revert.
- **Lesson**: renaming a brand is not a text substitution. Enumerate what you are changing, and assert on
  counts.

## 6. `ChatSession` "has no member 'streamDetails'"

- **Symptom**: a pile of errors that looked like a broken dependency:
  `value of type 'ChatSession' has no member 'generateParameters'`, `extra arguments in call`,
  `argument type 'ModelContainer' does not conform to expected type 'Decoder'`.
- **Evidence**: the last error is the tell — it means the compiler resolved the *only* initialiser it could
  see, `init(from: Decoder)`. A scan of all 1,431 app type declarations found
  `Agent/Chat/ChatStore.swift:42: struct ChatSession: Identifiable, Codable, Hashable` — **the app declares
  its own `ChatSession`** (the chat-*session record*), and a same-module declaration shadows an imported
  one. Earlier greps had missed it because BusyBox `grep` silently ignored `--include=*`.
- **Fix**: `MLXLMCommon.ChatSession` / `MLXLMCommon.Chat.Message` qualified throughout the local engine.
  A Python scan confirmed `ChatSession` was the only collision among the MLX names used.
- **Lesson**: "no member" on an imported type means you are looking at a different type.

## 7. New files registered but never compiled / never found

- **Symptom A**: "cannot find X in scope" — the file was in the project but added to the wrong
  `PBXSourcesBuildPhase` (the first one belongs to the UI **test** target).
- **Symptom B**: `Build input files cannot be found: src/ios/LocalModelHost.swift` — the reference was in
  **no group**, so `path = <name>` resolved against SOURCE_ROOT instead of its folder.
- **Symptom C**: `add_swiftpm.py` could not find the app target's phases at all.
- **Evidence**: reading `project.pbxproj` directly. The app target is `E51000040`, its phases are
  **short ids** (`E51000041`, `E51000020`) while everything else is a 24-char uuid — a regex matching
  `[0-9A-F]{24}` skips them silently.
- **Fix**: `scripts/add_sources.py` finds the target by `productType = "com.apple.product-type.application"`
  via a brace-balanced block scan, accepts `[0-9A-F]{8,24}`, and now resolves the **deepest existing
  ancestor group** so the reference's path is group-relative.
- **Lesson**: this project file is generated by hand and mixes id formats; assert, don't assume.

## 8. On-device model could be picked but never used

- **Symptom** (user): the model appeared in the picker and the header showed `__builtin_local_mlx__/…`,
  but chat could not proceed.
- **Evidence**: `ProviderConfigStore.entry(for:)` — it resolves `config.modelEntries` first, then the
  legacy uuid, then the legacy `:` composite. It has exactly one non-persisted exception, for the System
  *voice* engine, whose entries come from `SystemVoiceCatalog`. A synthetic provider has no entries, and
  ~127 call sites read `modelEntries`.
- **Cause**: the sentinel pattern fits voice (its own resolver) but not chat (persisted entries
  everywhere). Patching surfaces one at a time was chasing symptoms — which the user identified.
- **Fix**: a real `ProviderType.localMLX` (see the changelog, build 23). Older builds decode the raw value
  to `.unsupported`, the author's designed forward-compatibility path.

## 9. Large IPA installs time out; the phone must be awake

- **Symptom**: `asyncio.TimeoutError` from `install_signed.py`, three times in a row.
- **Evidence**: `Test-NetConnection 100.65.154.94 -Port 49152` → `False` while `ping` succeeded (88 ms).
  iOS closes the RemotePairing listener when the device is locked or asleep.
- **Fix**: wake/unlock the phone; the identical command then completed first try. Worth knowing before
  interpreting a timeout as a network fault.

---

## Verification toolkit (all under `looplab/tools/` and `D:\loopscope`)

| tool | what it answers |
|---|---|
| `crash_latest.py` | newest crash reports, symbolicated frames, exception + termination reason (uses `CrashReportsManager.parse`; `pull()` silently writes nothing on Windows) |
| `jetsam_today.py` | today's `JetsamEvent`s with the Nabla entry: reason, rpages (≈ GB), states |
| `install_signed.py` | install over the RSD tunnel and read the version back |
| `check_apps.py` | which bundle ids/versions are actually installed |
| `scripts/add_sources.py` | register new files in the app target's Sources phase (idempotent, asserts) |
| `scripts/add_swiftpm.py` | add a SwiftPM package/product (five coordinated pbxproj edits) |
| `scripts/rebrand_display_strings.py` | curated display-string rebrand with expected counts |
| `scripts/reapply_nabla_edits.py` | restore this round's edits after a revert |
| `scripts/local_provider_type.py` | the `.localMLX` provider-type insertion, every match count asserted |
| In-app **Measure** | decode tok/s and prefill on a short prompt — the engine's ceiling, isolated |
| In-app **Last turn** | prompt tokens, reused tokens, prefill ms, decode tok/s, TTFT |
