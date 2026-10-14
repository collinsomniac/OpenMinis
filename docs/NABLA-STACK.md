# Nabla — the stack as it stands

A record of *what this fork is made of* right now, so the next session does not have to rediscover it.
Upstream is `github.com/OpenMinis/OpenMinis` (GPL-3.0); this fork is `github.com/collinsomniac/OpenMinis`.

---

## 1. The app

| | |
|---|---|
| Product name | **Nabla** (`Nabla.app`), display name Nabla |
| Bundle id | `io.github.collinsomniac.nabla` → installed as `io.github.collinsomniac.nabla.FRJQU6T5U5` (the signer appends the team id) |
| App group | `group.io.github.collinsomniac.nabla.FRJQU6T5U5` — resolved at **runtime** from the embedded provisioning profile (`Shared/AppGroupResolver.swift`), never hardcoded |
| URL scheme | `nabla://` (was `minis://`); `nabla-mcp` |
| Backup extension | `.nablabak` |
| iCloud container | `iCloud.io.github.collinsomniac.nabla` |
| Version | `1.14 (build N)` where N is the CI run number |
| Installable alongside | App Store Minis (`com.openminis.app v1.14 (27)`) and LoopLab (`io.github.collinsomniac.looplab.FRJQU6T5U5`) |
| Source size | ~623 Swift files, ~299k LOC upstream |

**Entitlements that matter**: `com.apple.developer.kernel.increased-memory-limit` (verified **granted** on
this device; raises usable memory from ~3.25 GB to ~6 GB and measured as a ~3× decode-speed difference),
plus the app group. `scripts/prepare_sideload.py` reduces the target set for sideloading: main app only
(extensions each need their own App ID on a free account), bundle id rewritten, all deployment targets
raised to 26.2, entitlements trimmed.

## 2. Dependencies

**SwiftPM (app target)**

| package | version | why |
|---|---|---|
| `mlx-explore/mlx-swift-lm` | 3.32.3 (upToNextMinor) | MLX LLM/VLM runtime: `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`, **`MLXVLM`** |
| `ml-explore/mlx-swift` | 0.32.3 | `MLX` (arrays, Metal) |
| `huggingface/swift-huggingface` | 0.9.0+ | `HuggingFace` (Hub client) |
| `huggingface/swift-transformers` | 1.3.0+ | `Tokenizers` (tokenizer + chat templates) |
| `jamesrochabrun/SwiftAnthropic` | exact 2.2.0 | pre-existing |
| `swiftlang/swift-cmark` | 0.4.0+ | pre-existing (markdown) |
| `mgriebling/SwiftMath` | — | pre-existing (LaTeX) |
| `helloooideeeeea/RealTimeCutVADLibrary` | 1.0.0+ | pre-existing (dictation VAD) |

**Native build-time deps** (`deps/`): LAME, FFmpeg (LGPL), iSH, Alpine rootfs, rclone. ~40 min cold,
~12 min with the Actions cache.

**CI requirement**: `-skipMacroValidation -skipPackagePluginValidation`. mlx-swift-lm vends
`MLXHuggingFaceMacros` (the `#hubDownloader()` / `#huggingFaceTokenizerLoader()` macros) and a fresh
runner has trusted nothing, so the build fails without these flags.

## 3. Build → sign → install (no cable)

1. **CI** (`.github/workflows/build-ipa.yml`, runner `xcode-27`) builds the IPA and attaches it to release
   `openminis-N`.
2. **Sign** on the desktop: `D:\loopscope\nbsign.cmd` → `loopdeploy` (Rust + `isideload`), reusing
   iloader's keyring storage, `increased_memory_limit: true`. Must run in the **interactive** session via
   `schtasks /create … /ru colli /it` (Windows Credential Manager is unreadable from SSH, error 1312).
   Apple sends a fresh 2FA code per login attempt, so the signer polls `2fa.txt`.
3. **Pack**: `pack_ipa.py` — keeps the `Payload/` prefix and unix modes (zipfile defaults to 0600 and
   resolves symlinks).
4. **Install**: `install_signed.py` → RSD over Tailscale (`RemotePairingTunnelService`, port 49152,
   userspace TCP tunnel) → `InstallationProxyService.install_from_local`, then read the version back with
   `check_apps.py`.
5. **Verify** the version on device before believing anything.

Reachability facts worth remembering: the phone pings over Tailscale even when the port is closed, and
**iOS closes the RemotePairing listener while the device is locked** — a timeout usually means "wake the
phone", not "the network is broken". LAN lockdown (62078) is faster for large IPAs but requires the same
Wi-Fi network.

## 4. The device

| | |
|---|---|
| Model | iPhone 18,2 (iPhone 17 Pro Max) |
| OS | iOS 27.0 (24A435) |
| GPU | Apple A19 Pro GPU, working set reported 8.59 GB |
| RAM | 11.42 GB physical; **per-process ceiling ≈ 6.4 GB** with the entitlement (measured jetsam at 6.46 GB) |
| Bandwidth | ~56–60 GB/s effective — `tok/s ≈ 56 ÷ GB-read-per-token` |
| Thermal | ~20% throughput loss on a sustained run; reported `nominal` throughout |

## 5. Our additions (where the new code lives)

| path | what |
|---|---|
| `src/ios/Providers/LocalMLX/LocalModelStore.swift` | library, folder bookmark, **capability detection**, symlink-aware adopt, errors |
| `src/ios/Providers/LocalMLX/LocalModelHost.swift` | the engine: one resident model, admission control, generation, thinking parse, metrics, benchmark |
| `src/ios/Providers/LocalMLX/LocalModelCatalog.swift` | Hub inspection (files + sizes) for check-then-confirm |
| `src/ios/Providers/LocalMLX/LocalModelDownloader.swift` | **background URLSession** downloads, persisted jobs, staging → library |
| `src/ios/Providers/LocalMLX/LocalMLXProvider.swift` | `LLMProvider` + `AgentProvider`; turns carry images; capability → `modalityOverride` |
| `src/ios/Views/Settings/LocalInferenceSettingsView.swift` | the settings page, download sheet, performance readout |
| `src/ios/Shared/AppGroupResolver.swift` | runtime app-group resolution (crash fix, build 11) |
| `ProviderConfigStore.instance(for:)` / `builtInModels(for:)` / `hasUsableProvider` | the persistence seam the provider type plugs into |
| `AIChatView.performSend` | on-device pre-send confirmation; `micButtonContainer` gains the full-screen editor |

**Scripts** (repo root `scripts/`): `add_sources.py`, `add_swiftpm.py`, `rebrand_display_strings.py`,
`reapply_nabla_edits.py`, `local_provider_type.py`, plus upstream's `prepare_sideload.py` and
`rebrand_nabla.py`.

## 6. Reference measurements (LoopLab, same device)

Kept here because they are the baseline every "it feels slow" claim gets compared against.

| model | quant | decode | note |
|---|---|---|---|
| Qwen3-0.6B | 4-bit | **164.5 tok/s** | the 3-digit target; entitlement raised it from 43–54 |
| Llama-3.2-1B | 4-bit | 86 | |
| Ouro-1.4B | 4-bit, 1 loop | 78 | |
| Qwen2.5-Coder-1.5B | 4-bit | 70 | best quality-per-cost in the battery (28/30) |
| Qwen3-4B-2507 | 4-bit | 27.4 | |
| Qwen3.5-4B | 4-bit | 25.3 | |
| Qwen3.5-4B | **8-bit** | ~11 | 4.4 GB read per token against ~56 GB/s |
| Metal simd bandwidth | — | 66.8 GB/s | healthy state; a halved reading (36–38) cleared with a reboot |

Loop scaling, speculation, KV quantisation and MoE results from the same corpus are in
`docs/STATUS.md` and the LoopLab docs mirror.
