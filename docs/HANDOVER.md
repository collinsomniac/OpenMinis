# LoopLab — handover guide for a future agent

Everything needed to pick this up cold: the two machines, how to build and install, how to run
experiments, what has been measured, what is broken, and which beliefs are still unverified.

---

## 1. The two machines

**Phone** — iPhone 17 Pro Max (`iPhone18,2`), iOS 27.0, 12 GB RAM, A19 Pro GPU.
- UDID `00008150-001139383A52401C`, Tailscale `100.65.154.94`, LAN `192.168.4.22`.
- 5.96 GB usable memory (needs the `increased-memory-limit` entitlement — see §5).
- Sideloaded with a **free Apple ID**, so provisioning profiles expire every **7 days** and need re-signing.

**Desktop** — Windows 10 (`DESKTOP-3RSF4R5`), i7-6700K, 32 GB RAM, GTX 1070.
- Tailscale `100.113.239.4`, LAN `192.168.4.28`. Reached from the phone's iSH with
  `ssh -F /var/minis/shared/mdp/ssh/config rig`.
- **The remote shell is Git Bash, not cmd.** Backslashes are eaten: always use forward slashes
  (`D:/loopscope/x.py`), and prefer uploading a `.cmd`/`.ps1` over complex inline quoting.
- Python: `C:\Python311`, `C:\Python312`, and **`C:\Python313`** (per-user at
  `%LOCALAPPDATA%\Programs\Python\Python313\python.exe`) — the 3.13 one is required for the
  wireless tunnel (§4).
- Rust: `D:\.cargo\bin\cargo.exe`.
- iloader (patched, see §5): `C:\Users\colli\AppData\Local\iloader\iloader.exe`.

## 2. The pieces of the system

| piece | what it is |
|---|---|
| **LoopLab** (`github.com/collinsomniac/looplab`) | the sideloaded iOS app: MLX model host, job runner, benchmark batteries, Shortcuts actions, terminal UI, on-device model library |
| **mlx-swift-lm fork** (`collinsomniac/mlx-swift-lm`, branch `ouro-3.32.3`) | MLX inference library with Ouro (looped model) support added |
| **iloader fork** (`collinsomniac/iloader`) | sideloading tool with the memory-entitlement fix (upstream passed `false` for `increased_memory_limit`) |
| **desktop sink** (`D:\loopscope\sink.py`) | job queue + result sink + **per-run terminal logs**, served on `:8791`, published over the tailnet at `https://desktop-3rsf4r5.tailce70fb.ts.net:8443` |
| **job batteries** (`D:\loopscope\queue\*.json`) | test specs the phone fetches and runs; results append to `D:\loopscope\jobs.jsonl` |

**The workflow**: the agent writes a battery JSON, POSTs it to `/queue/add`, the user taps
**Run queue** in the app, results stream back to `jobs.jsonl`, and every run's raw terminal output is
stored at `D:\loopscope\terminal\<run>\terminal.log` next to the spec that produced it.

```bash
H=desktop-3rsf4r5.tailce70fb.ts.net; R="--resolve $H:8443:100.113.239.4"
curl -s $R -X POST -H 'Content-Type: application/json' --data-binary @job.json https://$H:8443/queue/add
curl -s $R https://$H:8443/health
```

## 3. Building and releasing the app

1. Edit under `/var/minis/workspace/looplab/` (the repo checkout used by the agent), commit, push to `main`.
2. GitHub Actions builds on an `xcode-27` runner, ad-hoc signs **with entitlements**, and publishes a
   release named `build-N` containing the IPA and a SideStore source JSON.
3. Fetch the IPA to the desktop:
   ```bash
   ssh -F ... rig "cd /d/loopscope && curl.exe -sL --fail -o LoopLab-latest.ipa '<release asset url>'"
   ```
4. Install (§4 or §5).

**CI gotchas that cost real time**: Xcode 27 needs `xcodebuild -downloadComponent MetalToolchain`;
Swift 6 mode rejects `[String: Any]` across actors (the project pins `SWIFT_VERSION 5.0` and uses a
`JSONBox` wrapper); the workflow's `paths:` filter once silently excluded a fix; and the SideStore
source JSON must advertise the same version string as inside the IPA.

## 4. Installing with no cable (verified working)

Prerequisites, once: pair over USB (§4.1) and use **Python 3.13**. After that, everything runs over
Tailscale with the phone anywhere on the tailnet.

### 4.1 One-time pairing (needs the cable, ~20 s, promptless)
```python
lockdown = await create_using_usbmux(serial=UDID, autopair=False)
svc = await RemotePairingLockdownService.create(lockdown)
await svc.connect(autopair=True)          # raises RemotePairingCompletedError when done
```
This writes `~/.pymobiledevice3/remote_<udid>.plist` (Ed25519 key pair + `peer_alt_irk` +
`remote_unlock_host_key`). **No trust dialog appears** — that is expected.

### 4.2 Connect and use device services over Tailscale
```python
T.USE_USERSPACE_TUNNEL = True
svc = T.RemotePairingTunnelService(UDID, "100.65.154.94", 49152)
await svc.connect(autopair=False)                       # pair-verify
async with T.start_tunnel_over_remotepairing(svc, protocol=TunnelProtocol.TCP) as tun:
    tun_obj = cast(UserspaceTun, tun.client.tun); tun_obj.set_peer(tun.address)
    async with UserspaceDialPlane(tun_obj, tun.address) as plane:
        rsd = RSD((tun.address, tun.port), open_connection=plane.dial,
                  auxiliary_metadata=tun.auxiliary_metadata)
        await rsd.connect()
        ip = InstallationProxyService(rsd)               # RSD satisfies LockdownServiceProvider
        apps = await ip.get_apps(application_type="User")
```
Working scripts: `tools/rsd_apps.py` (list apps), `tools/rsd_services.py` (list services).

**Rules that are not obvious**: the tunnel must be **TCP** (iOS 18.2+ removed QUIC); the RSD address
lives **inside a userspace TCP stack**, so services must be dialled through `UserspaceDialPlane.dial`
passed as `open_connection=`; RSD service names carry a **`.shim.remote`** suffix; and
`rsd.start_remote_service()` returns an *unconnected* connection — do not await it.

### 4.3 Signing and installing (working)
Installing needs a provisioning profile tied to the user's Apple ID. Done with **`tools/loopdeploy`**
(Rust + `isideload`, reusing iloader's keyring session) → **`tools/pack_ipa.py`** → then
**`tools/install_signed.py`** over the RSD tunnel. **`tools/deploy.py`** runs all of it.
Verified: build 24 installed over Tailscale with the phone unplugged.
Run the signer in the interactive session (keyring is unreadable from SSH), and note that Apple issues
a **fresh 2FA code per attempt** — the signer waits for it in `2fa.txt`. Full detail, including the
three traps, is in `docs/WIRELESS-INSTALL.md` §4.

## 5. The memory entitlement (why it matters)

Without `com.apple.developer.kernel.increased-memory-limit` the app gets ~3.25 GB instead of 5.96 GB,
and decode runs at **~40% speed** (Qwen3-0.6B 43–54 tok/s instead of 164). The cause is the jetsam
ceiling starving MLX's buffer pool, forcing per-token Metal buffer allocation.
iloader upstream never requested it; our fork's one-line fix (commit `74f75ee`) is why builds work.
**A rebuild must keep requesting that entitlement, and the install must go through iloader (or any
signer) that carries it.**

## 6. Running experiments

- Batteries live in `jobs/*.json` in the research tree; ops include `probe`, `load`, `unload`,
  `generate`, `decide`, `bench_decode`, `bench_spec`, `bench_metal`, `bench_blit`, `set_loops`,
  `bench_loops`, `read_bench`, `library`, `echo`, `load_draft`, `unload_draft`.
- **Always record thermal** (it swings ~20%) and compare within one session.
- **Check `read_bench` results against expectations**: if a small model reports 18–25 GB/s it is
  reading from the page cache, not flash (F_NOCACHE does not evict resident pages).
- **Scoring is done on the desktop** from `jobs.jsonl`; never trust the app's own summary line.
- A regression guard exists in spirit but not in code: **run `bench_metal` first**. simdgroup should
  be **66–70 GB/s**. If it reads ~36–40, the device or app is in a degraded state and *all* speeds
  that session are relative only (this happened in builds 22–23 and is not yet explained — §7).

## 7. What is measured, and what is still open

**Measured (see `docs/STATUS.md` for numbers)**: decode is bandwidth-bound at ~56 GB/s ÷ bytes per
token; loops cost time linearly and quality plateaus at 2; MoE speed tracks *active* bytes (a 3.9 GB
7B MoE beat a 1 GB dense model); speculation helps code (×1.2–1.4) and hurts prose (×0.6–0.9); KV
quantization only pays at long context; flash reads at 1.4–3.6 GB/s; thinking-mode models burn the
token budget unless `enable_thinking=false`.

**Open**:
- The build-22/23 speed regression (all models ~40%, including our own Metal kernel) — ruled out:
  terminal, tab, thermal state, Low Power Mode, entitlement, MLX versions, weights source. Not yet
  tested: reboot, and a same-hour comparison against build 20 (staged at `D:\loopscope\LoopLab-build20.ipa`).
- Whether the phone's "Paired Computers" screen can ever browse for pairable hosts (it did not, with a
  verified-live advertisement) — hence the one-time cable pairing.
- Why lockdownd over TCP works on the LAN but not over Tailscale (RSD works; the classic path does not).

## 8. Immediate next steps

1. ~~Deploy worker~~ **done** — `tools/deploy.py` (fetch → sign → pack → install → verify).
2. **Reboot test** for the §7 regression.
3. **Shortcuts**: move model actions to iOS 27's long-running intent type (background GPU + Live
   Activity), then add Extract (schema → dictionary) and typed answers.
4. **Inference**: prompt-cache reuse, adaptive loop depth, per-task routing, expert caching for MoE.
5. **Learning at inference** — `docs/LEARNING.md`.
