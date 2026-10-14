# Method — how findings in this project were reached

Not a log of everything, but the reasoning pattern and the specific hypotheses that were tested and
resolved. Written so a future agent can tell *which* claims are measured, which are inferred, and
which were guesses that turned out wrong.

## The working rules

1. **Measure on the device, not from published numbers.** Published iPhone MLX benchmarks said
   Qwen3-0.6B should run at ~179 tok/s. We measured 43–54, then 164 after fixing the entitlement.
   The difference was a configurable, findable cause — not the hardware.
2. **Distrust the first result; ask what else it could be.** A "0/36" model score was not a model
   failure but a chat template that thinks by default plus a token budget that cut it off mid-thought.
   A "2× faster" MoE was real, but the *same session* was running at 40% speed for an unrelated reason.
3. **Prefer an A/B inside one session.** Thermal swings ~20%, so a comparison across sessions is not
   trustworthy. Build a job that alternates the condition (e.g. `echo` off/on/off) and compare medians.
4. **Separate the artifact from the effect.** If a change alters a *measurement* (scorer, prompt
   format, cache state) rather than the system, fix the measurement before drawing conclusions.
5. **State what a number cannot show.** "Lossless" speculation produced different text — because
   batched verification reorders floating-point reductions and flips near-ties. Both outputs were
   valid; the claim had to be weakened to "lossless up to numerics".

## Case 1 — the memory entitlement (resolved)

**Observation**: decode at 43–54 tok/s; our own Metal kernel 36–39 GB/s, unstable, with 9.6 outliers.
**Hypothesis A**: the GPU is slower than advertised. **Test**: a pure Metal streaming kernel, no MLX.
→ It reached 66–68 GB/s *after* the entitlement was granted, so the hardware was fine.
**Hypothesis B**: MLX is misconfigured. **Test**: version and parameter sweep. → No effect.
**Resolution**: `os_proc_available_memory` showed 3.25 GB instead of ~6 GB. The jetsam ceiling was
starving MLX's buffer pool, so buffers were reallocated per token. Fixed by requesting
`increased-memory-limit`; iloader upstream passed `false` for that flag at its only call site, and
isideload enables the App ID capability *before* fetching the profile, so flipping it was sufficient.
**Result**: 3.25 → 5.96 GB, decode 43–54 → 144–168 tok/s, kernel stable at 66–68 GB/s.

## Case 2 — "1 loop is enough" (resolved, and wrong)

**Supposition** (from the literature): looped models gain little from extra recurrence.
**Test**: 12 prompts × 2 runs at 1, 2 and 4 loops, texts scored on the desktop.
**Result**: 1 loop **4/24**, 2 loops **20/24**, 4 loops **20/24**. The entire benefit arrives at loop
2 — and 4 loops *broke* an arithmetic answer that 2 loops got right, while fixing the hardest item.
**Lesson**: depth is useless *on average* but not universally, which is exactly why the right policy is
per-token/per-prompt rather than a fixed count. An average hid a bimodal effect.

## Case 3 — the build-22/23 speed regression (open)

**Observation**: every model ~40% of its build-20 speed (1.7B 62 → 26.6 tok/s).
**Hypothesis A**: the new live terminal re-renders a large string per token.
**Test**: an `echo` switch in the job spec, alternating off/on/off within one session.
→ **Ruled out**: ±2%.
**Hypothesis B**: the visible tab matters. **Test**: the same battery run twice, on the Queue tab and
on the Device tab, with the active tab recorded per step. → **Ruled out**: no difference.
**Hypothesis C**: thermal or Low Power Mode. → **Ruled out**: thermal reported *nominal*, LPM off.
**Hypothesis D**: the entitlement regressed. → **Ruled out**: still granted, still 5.96 GB.
**Hypothesis E**: dependency drift (a new MLX version). → **Ruled out**: unchanged since build 16.
**Hypothesis F**: reading weights from the Files library instead of the Hub cache.
→ **Ruled out**: identical files, and the *pure Metal* bench regressed too — it shares no code with
MLX or the model path, and dropped from 68–70 to 36–38 GB/s.
**Key clue**: our own kernel, which involves no model, no MLX and no terminal, halved. So the GPU
itself ran at half bandwidth for everything.
**Still to test**: reboot the phone; and run the same bench on the staged build 20 at the same hour.
**What this cost**: every speed number from those sessions is relative only, and has to be re-measured.

## Case 4 — wireless installation (resolved, after three wrong turns)

**Goal**: install a freshly built IPA with no cable.

**Supposition 1** — *replace the USB transport with a virtual USB device.*
**Resolution**: unnecessary. The phone's device services are reachable over Tailscale directly: TCP to
`100.65.154.94:49152` (RemotePairing) and `:62078` (lockdown) connects from the desktop across the
tailnet, identically to the LAN. Replacing the *data path* is the wrong layer; the services already
speak TCP.

**Supposition 2** — *discovery is the problem, so reproduce Bonjour.*
**Test**: browse mDNS from the desktop. → The phone advertises `_remotepairing._tcp` (identifier
`006A7A56-…`, port 49152) and `_apple-mobdev2._tcp` (`supportsRP-26`). The port is **fixed**, and the
client accepts an explicit address, so Bonjour is only needed to *discover* it — never to use it.

**Supposition 3** — *pair the phone without a cable via iOS 27's device-initiated pairing.*
**Test**: run `remote pair-host`, then publish the advertisement ourselves.
→ Two concrete bugs found and fixed: pymobiledevice3's own mDNS **publisher silently fails on
Windows**, and the `zeroconf` library refuses Apple's 27-byte service label unless `strict=False`.
With both fixed, the advertisement was verified live on the LAN (`192.168.4.28:45999`).
**Resolution**: the phone still showed nothing — Settings › Developer › **Paired Computers** lists only
existing pairings and never browsed for a pairable host. So a cable-free *first* pairing is not
available here, the same constraint Apple puts on its own wireless debugging.

**Supposition 4** — *reuse iloader's existing pairing record.*
**Test**: read `rppairing1.1_file_<udid>` from Windows Credential Manager (via a scheduled task running
in the interactive session — an SSH session gets error 1312), convert it to pymobiledevice3's schema,
connect to port 49152.
**Resolution**: the phone accepted the TLS setup and then **terminated the connection during
pair-verify** — it holds a *different* public key for that host label. iloader caches the label and the
key pair separately, so a regenerated key pair keeps the old name on the device. A stale record that
*looks* current. A fresh pairing was required.

**Resolution**: `RemotePairingLockdownService` performs pair-setup over **USB lockdown**, promptless,
and writes the record the network tunnel consumes. One cable connection, once. After that:
pair-verify over Tailscale → RSD tunnel → 64 services → `installation_proxy` lists 76 apps.

**Four details that were each a blocker, in order**: iOS 18.2+ removed QUIC, so the tunnel must be TCP;
the TCP tunnel needs **Python 3.13** (on 3.12 the PSK module installs but its OpenSSL DLL fails to
load); the RSD address lives **inside a userspace TCP stack**, so services must be dialled through
`UserspaceDialPlane.dial`; and RSD service names carry a **`.shim.remote`** suffix.

**What remains**: signing. The transport is done; an IPA still needs a provisioning profile tied to
the user's Apple ID, which `isideload` provides (`sign_app` + `install_app_rsd`).

## Recurring traps

| trap | how it shows up | guard |
|---|---|---|
| page cache | a 1 GB model "reads" at 18–25 GB/s | compare against the 1.4–3.6 GB/s flash figure; F_NOCACHE does not evict resident pages |
| thermal | same config 78.8 → 63.4 tok/s | record thermal; compare within a session |
| token budget | correct answers scored wrong | size budgets per model; strip think blocks before scoring |
| chat template | a model "fails" every task | check `enable_thinking`; score what the model actually said |
| backend shell | `D:\path` becomes `D:path` | forward slashes, or upload a `.cmd`/`.ps1` |
| base64 over SSH | "invalid input", truncated files | pipe through stdin to a `.b64` file, decode with Python |
| Windows Credential Manager | error 1312 from SSH | scheduled task with `/ru <user> /it`, or the Win32 API |
| one `as? Int` cast | UInt64 values rendered as 0.00 GB | a `bytes(_:)` helper that handles every numeric type |
