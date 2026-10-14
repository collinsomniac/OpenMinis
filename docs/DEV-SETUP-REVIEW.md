# What our development setup grants us — and how to use it better

An inventory of the machinery we have assembled across LoopLab and Nabla, what each part makes possible,
how much of that we actually use, and the additions that would make the lower-level work cheaper. It's
written from the inside: these are the things that made the last three weeks possible, and the frictions
that slowed them down.

---

## 1. The assets

| asset | what it is | what it uniquely enables |
|---|---|---|
| **Source of the whole app** (OpenMinis fork, GPL-3.0, ~299k LOC) | Swift app with a tool loop, iSH Linux, MCP, sub-agents, skills, providers | Changing the agent, the UI and the providers — not just configuring them |
| **Source of the whole inference stack** | mlx-swift-lm → mlx-swift → mlx C++ core (`1f8e74e3`) → **132 Metal kernels**, all compiled by every CI build | Kernel-level optimisation, new model architectures, new decode strategies (§3 of ENGINE-FORK.md) |
| **A proven fork of the inference stack** | `collinsomniac/mlx-swift-lm` branch `ouro-3.32.3` (looped models) | The mechanics of carrying a patch against upstream already work |
| **CI on real Apple toolchains** | GitHub Actions `xcode-27`, native deps cached (~12 min warm) | Building iOS without a Mac. Every compile error so far was caught there, not on the phone |
| **Cable-free deploy** | Tailscale → desktop signer (isideload, iloader keyring, memory entitlement) → RSD tunnel install → version read-back | Edit → installed build, from a phone, with no cable |
| **Device introspection over the same tunnel** | `CrashReportsManager`, jetsam/resource reports, installation_proxy | Classifying failures (crash vs jetsam vs hang) from the phone's own reports — this is how the "crash" was identified |
| **A measurement app on the same device** | LoopLab: batteries, Metal bandwidth bench, model library, remote job queue via desktop sink | A baseline every claim is compared against (164.5 tok/s, 66.8 GB/s, thermal curves) |
| **The in-app agent** (this conversation) | shell, files, browser, sub-agents, MCP (GitHub, Supabase), memory, scheduling | Research, code, build and deploy from one place, with sub-agents doing parallel recon |
| **The desktop** (Windows, Python 3.13, pymobiledevice3, GTX 1070) | signer + tunnel host + CPU compute | Signing, tunnels, CPU-side conversions and tooling. The GPU is off-limits for heavy work (two prior crashes) |
| **The device** | iPhone 17 Pro Max, A19 Pro, ~6.4 GB per-process ceiling, ~56–67 GB/s | The actual target — there's no emulator for this |

## 2. How well we use it (honest)

- **Well:** the build/deploy loop; CI as a compiler; reading library source before writing against it
  (it turned three would-be guesses — `fork` doesn't exist, `ChatSession` shadowing, the top-p sort — into
  certain fixes); crash/jetsam classification.
- **Under-used:** LoopLab. It's the best measurement instrument we have, and Nabla hasn't been measured
  *with* it — Nabla's numbers come from its own readout or from user screenshots. The engine work should
  be benchmarked in LoopLab, where the job queue, the batteries and the thermal discipline already exist.
- **Not used yet:** our ability to fork the *kernels*. Every optimisation so far has been Swift-level
  configuration, which is right as a first step, but the largest remaining gains (ENGINE-FORK §3) are
  below that line.
- **The bottleneck is me observing the app.** Every UI or behaviour check went through a screenshot
  from the user (AGENT-INSIDE-THE-APP.md §1).

## 3. Additions that would make low-level work cheaper

Ranked by how much they would compress the iteration loop.

1. **A headless benchmark mode reachable over the tunnel.** LoopLab already accepts jobs from the
   desktop sink. Give Nabla's engine the same entry point, or simply port the engine into LoopLab as a
   second harness. Then an engine change becomes: build → install → queue a battery → read numbers, with
   no human in the loop. This matters most for kernel work, where every change needs a before/after.
2. **Determinism checks.** Greedy decode with a fixed prompt set, compared token-for-token against the
   vanilla engine. A kernel fork is only safe when this passes. It's cheap to build in LoopLab's job
   format.
3. **Promote the app's DEBUG introspection server to an opt-in Release feature** (AGENT-INSIDE-THE-APP §3):
   `app_state`, `app_view_tree`, `app_screenshot`, `app_logs`. It removes the screenshot bottleneck for UI
   work. The pairing/auth design already exists.
4. **A fork dependency switch in CI.** One workflow input: build against upstream MLX *or* our fork.
   Then every engine change produces two IPAs from one commit, and the A/B comparison is honest.
5. **Desktop CPU-side model tooling** (already feasible): extracting MTP heads from official
   checkpoints, re-quantising, checking weight indexes. Python + safetensors on the desktop CPU, no GPU.
6. **Smaller IPAs, faster installs.** 86 MB is installing near the RSD tunnel's tolerance (we hit
   timeouts). LAN lockdown (62078) is faster when on the same Wi-Fi; stripping debug symbols from the
   native deps would also help.

## 4. Where this leads (the next three passes, consolidated)

**Pass A — measure what we have (no fork)**
- Install build 29 (staged: residency fix, KV precision, tool calling).
- In-app: KV precision sweep on the 0.6B at real context; reused-token check across turns; a tool-calling
  task on the 0.6B and the 4B; a photo to the 4B.
- Switch the 4B to 4-bit (`mlx-community/Qwen3.5-4B-MLX-4bit`, 3.06 GB, verified on the Hub).

**Pass B — MTP for Qwen3.5 (no fork)**
- Load an MTP head via `MTPDrafterModelFactory`. Source: OptiQ's `optiq/mtp.safetensors`, or extract the
  15 `mtp.*` tensors from `Qwen/Qwen3.5-4B` on the desktop.
- Decode path: `generate(…mtpDrafter:blockSize:)`. Measure acceptance and speedup in LoopLab.
- Known limit: vanilla MTP falls back to single-token decode when KV is quantized.

**Pass C — the fork (only if A/B confirm the model)**
- mlx: fused quantized-KV `sdpa_vector` variant. Bar: ≥15% over vanilla quantized KV at 6.6k context,
  token-identical greedy output.
- mlx-swift-lm: MTP that survives quantized KV.
- Upstream both if they hold up.

Running in parallel with these: the agent-manager / multiplexer work (separate design document), which
needs none of the engine work.
