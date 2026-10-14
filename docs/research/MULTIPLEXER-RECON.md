# Multiplexed Agent Managers — Recon & Design Concept for an OpenMinis Fork

_Compiled 2026-10-11. Sources were checked live via the GitHub API and the docs sites (star counts and last-push dates are as of that day). Where something is my inference rather than documented, it says so._

---

## 0. TL;DR

1. **Herdr** ([herdrdev/herdr](https://github.com/herdrdev/herdr), [herdr.dev](https://herdr.dev), Apache-2.0, Rust, about 43k★) is the closest existing match to what you want. It is a tmux-like server/client runtime built for coding agents: workspaces → tabs → panes, per-pane agent state (`working / blocked / done / idle / unknown`), several SSH machines in one sidebar (with a Windows x86_64 server too), and a **newline-delimited JSON socket API** (`pane.send_text`, `pane.read`, `agent.prompt`, `agent.wait`, `events.subscribe`, `session.snapshot`). Its integration contract (env vars plus a `report-agent` CLI) is a pattern you can copy directly. A whole ecosystem of phone/web clients already sits on that socket.
2. **OpenRig** ([mvschwarz/openrig](https://github.com/mvschwarz/openrig), [openrig.dev](https://openrig.dev), Apache-2.0, TS, about 7k★) is the *coordination* layer: rigs → pods → seats (agents) in YAML, a daemon with SQLite and HTTP on :7433, tmux as **transport only** ("tmux is transport, not truth"), durable chat/queue/stream tables, an MCP server (`rig_send`, `rig_capture`, `rig_chatroom_send/watch`), cross-host over SSH or HTTP, and a strict, honest agent-state taxonomy. It is the best model for how mixed agents *cooperate*.
3. **"Remux" is ambiguous.** The most relevant hit is **[h3nock/remux](https://github.com/h3nock/remux)** ([getremux.app](https://getremux.app), about 500★): a native iOS tmux client built on Ghostty with Citadel SSH. **[viminizer/remux](https://github.com/viminizer/remux)** is a Go binary with embedded `tsnet` plus a PWA that supervises tmux agents from a phone without ever attaching as a tmux client. Several other small or unrelated "remux" repos exist (one is a Jellyfin server); they are listed in §3.
4. **tmux control mode (`-CC`)** is the right *structured* SSH transport: `%output %pane …`, `%extended-output` with flow control (`pause-after`), format subscriptions (`refresh-client -B`), and pane user-options (`@foo`) for metadata. The catch: an attached client resizes panes. viminizer/remux avoids that by using only `capture-pane` and `send-keys`, never attaching.
5. **Use structured agent protocols where they exist.** Codex has `codex app-server` (JSON-RPC over stdio, unix socket or ws, with token auth; `thread/start`, `turn/start`, `item/*` deltas, approval requests). Claude Code has `-p --output-format stream-json --input-format stream-json`, hooks (`Notification`, `Stop`, `PermissionRequest`…) and its own Remote Control. Screen-scraping (Herdr manifests, claude-squad hash diffing, agentapi's terminal snapshot diff) is the universal fallback.
6. **iOS reality:** the phone can't keep sockets open in the background. Remote state must live in tmux, Herdr or a small daemon on each host. The phone reattaches on foreground, and APNs/ntfy push (sent from the host side) handles "agent blocked" alerts.

---

## 1. Herdr

| | |
|---|---|
| Repo | https://github.com/herdrdev/herdr (≈43.5k★, pushed 2026-10-11, Apache-2.0, single Rust binary) |
| Docs | https://herdr.dev/docs/ — [concepts](https://herdr.dev/docs/concepts/), [session state](https://herdr.dev/docs/session-state/), [connecting machines](https://herdr.dev/docs/connecting-machines/), [persistence/remote](https://herdr.dev/docs/persistence-remote/), [socket API](https://herdr.dev/docs/socket-api/), [agents](https://herdr.dev/docs/agents/), [add herdr support](https://herdr.dev/docs/add-herdr-support/), [agent skill](https://herdr.dev/docs/agent-skill/), [plugins](https://herdr.dev/docs/plugins/) |
| Tagline | "the runtime your coding agents live on" |

**Architecture.** A background **server** owns the PTYs and processes. **Clients** (the TUI, or other clients) attach and detach (`ctrl+b q`). The model is **Session** (separate server namespace, own socket) → **Workspace** (per repo or task; its sidebar state rolls up from the agents inside) → **Tab** (a layout) → **Pane** (a real terminal). When several clients are attached, each one can look at a different tab. If they look at the same tab, the last one to interact decides its size.

**Persistence (tiered, documented honestly):**
- *Detach/reattach:* processes keep running. This is the strongest guarantee.
- *Server restart:* layout, cwd and focus come back from `session.json` (with 48 rotating snapshots and a backup on parse failure). The processes themselves are gone.
- *Pane screen history replay:* opt-in (`[experimental] pane_history`). It is off by default because scrollback can contain secrets.
- *Native agent session restore:* integrations report a resume argv (`claude --resume <id>`, `codex resume <id>`, `opencode --session <id>`, …). After a restart, Herdr reruns that argv in the saved cwd.
- *Live handoff* (`herdr update --handoff`): passes live PTYs to a new server binary (experimental).

**Agent state detection.** Herdr finds the agent's foreground process in each pane, then reads the **live bottom of the screen** and matches it against per-agent **detection manifests**. If an integration (or the agent itself) reports state, that report wins over scraping. "Blocked" is deliberately strict: it only fires on a known approval/question UI. When unsure, Herdr says `unknown` (Codex) or `idle`. `agent.explain` shows why a state was chosen. "Done" vs "idle" is tracked per client: done means finished but not yet seen.

**Integration contract (very reusable).** Every pane gets `HERDR_ENV=1`, `HERDR_PANE_ID`, `HERDR_BIN_PATH` and `HERDR_SOCKET_PATH`. An agent or hook reports like this:
```
$HERDR_BIN_PATH pane report-agent $HERDR_PANE_ID --source my-agent --agent my-agent \
  --state working|idle|blocked --seq <monotonic> [--message …] [--agent-session-id ID -- my-agent --resume ID]
$HERDR_BIN_PATH pane release-agent $HERDR_PANE_ID --source my-agent --seq N
```
The rules: `seq` must only go up (late reports are dropped), send reports fire-and-forget, keep only the newest state, and the resume argv is validated (plain command on PATH, ≤64 args, ≤8 KiB).

**Output streaming and input injection.** The socket transport is **newline-delimited JSON** over a Unix socket (a named pipe on Windows), as `{"id","method","params"}` requests and `result/error` responses. Methods include `pane.send_text / send_keys / send_input` (key-combo strings such as `ctrl+c` or `enter`), `pane.read --source recent --lines N`, `pane.wait_for_output`, `agent.prompt` (with an optional atomic wait; it refuses with `agent_blocked` if the agent is waiting on a decision), `agent.wait --until done`, `events.subscribe` (`pane.created/closed/exited/output_matched/agent_status_changed/scroll_changed`, …), and `session.snapshot` for cache bootstrap ("subscribe first, then reconcile"). `herdr api schema --json` prints the full JSON Schema.

**Remote model.** `herdr --remote host` or saved machines (`herdr machine add workbox`). The remote server owns the panes and streams screen content over **SSH** with compression and keepalives. The local client draws the UI. Herdr manages an OpenSSH ControlMaster (`ControlPersist 600`). Only the **selected** machine streams pane screens; the others send just workspace and agent state and notifications. That is exactly the bandwidth model a phone grid needs. Each machine reconnects on its own. Supported servers: Linux and macOS (x86_64/aarch64) and **Windows x86_64** (ConPTY).

**Agent-native features.** A bundled `SKILL.md` lets agents split panes, run commands, read neighbours, start helper agents and wait on each other. A plugin marketplace exists, with plugins written in any language (a `herdr-plugin.toml` manifest plus commands).

**Ecosystem built on the socket (useful prior art for the phone UI):**
- [devswha/herdr-web-ui](https://github.com/devswha/herdr-web-ui) (≈835★, MIT): a browser/PWA client. It reads each agent's **own transcript store** (Claude/Codex session files) and shows it as chat, turns approvals into tap cards ("checked to be current before your answer is sent"), sends web push alerts, publishes QR codes over `tailscale serve`, and supports remote PCs over SSH. On Windows it falls back to a "screen mirror".
- [dcolinmorgan/herdr-remote](https://github.com/dcolinmorgan/herdr-remote): menu bar, phone and Telegram clients; one-tap approvals; a relay or tunnel.
- [missuo/herdrm](https://github.com/missuo/herdrm): a native macOS console across devices (SSH, Tailscale, Keychain).
- [penso/herdr-gpui](https://github.com/penso/herdr-gpui): a native GPUI client.
- [eliasstravik/herdr-projects](https://github.com/eliasstravik/herdr-projects): a coordinator conversation plus worker threads (one worktree each), shared memory, and a "needs you" grouping. **Closest to your "group" concept.**

**Reusable for you:** the state vocabulary, the report-agent env contract, NDJSON plus the snapshot-then-subscribe pattern, the "stream only the focused machine" rule, the tiered persistence semantics, and Herdr itself as a ready remote backend (it runs on the Windows desktop and the Linux boxes).

---

## 2. OpenRig

| | |
|---|---|
| Repo | https://github.com/mvschwarz/openrig (≈7k★, pushed 2026-10-12, Apache-2.0, `@openrig/cli` on npm) |
| Site | https://openrig.dev |
| Key docs | [ARCHITECTURE.md](https://github.com/mvschwarz/openrig/blob/main/ARCHITECTURE.md), [transport-and-transcripts](https://github.com/mvschwarz/openrig/blob/main/docs/as-built/architecture/transport-and-transcripts.md), [coordination-primitive](https://github.com/mvschwarz/openrig/blob/main/docs/as-built/architecture/coordination-primitive.md), [agent-state-taxonomy](https://github.com/mvschwarz/openrig/blob/main/docs/reference/agent-state-taxonomy.md), [cross-host skill](https://github.com/mvschwarz/openrig/blob/main/skills/_canonical/core/cross-host-rig-commands/SKILL.md), [rig-spec](https://github.com/mvschwarz/openrig/blob/main/docs/reference/rig-spec.md) |
| Name check | Do not confuse it with EpicGames/OpenRigLogic (a character rig library) or EliasOenal/OpenRig (sandboxed multi-user runtime). |

**Architecture.** "A harness wraps a model; a rig wraps your harnesses." A local **daemon** (Hono HTTP on `:7433`, SQLite in WAL mode) runs each agent as an **unmodified** Claude Code, Codex, Pi or OMP session (or a plain terminal) inside **tmux**. The `rig` CLI, the TUI and an **MCP server** (`rig mcp serve`, 18 `rig_*` tools) all talk to the daemon. A terminal WebSocket route exists. Herdr or cmux is the preferred *viewing* surface; plain tmux is the fallback.

**Grouping model.** **Rig** (a team) → **pod** (sub-team, e.g. development/review/orchestration) → **seat** (a role with an agent, addressed as `dev-build@starter`). Teams are defined in YAML (`rig.yaml` plus `agent.yaml` per seat) and booted with `rig up`. Bundles can be shared (`.rigbundle`).

**Messaging / cooperation (the most reusable part):**
- `rig send <seat> "msg"` → `POST /api/transport/send`. The send resolves the seat, takes a **per-seat serialized delivery lease**, and **classifies send readiness**: it refuses with `target_needs_input` when the pane shows an interactive prompt, unless you pass `--dangerously-interact --reason`, which is audited. An optional "typing guard" *holds* messages instead of typing them into a pane the human is using. It then types the message via tmux.
- `rig capture` uses `tmux capture-pane`. Transcripts are bounded periodic captures stored as files (ANSI stripped, searched with rg or grep).
- **Durable chat** (`chat_messages` table plus an SSE `/watch`) and a **stream/queue/inbox/outbox** coordination primitive. `queue_items` have states `pending | in-progress | done | blocked | failed | denied | canceled | handed-off`, with closure reasons and a chain of record. "Sending a message does not create a queue item; the recipient records the task."
- Activity hooks for Claude and Codex POST event type and identity (no prompt text) to `/api/activity/hooks`.
- tmux pane user-options tag identity: `@rigged_node_id`, `@rigged_session_name`, ….

**State detection:** a three-axis taxonomy:
- *session:* present / detached / exited / absent
- *activity:* working / idle-at-prompt / unknown, plus **needs-input as `{count, reason}`**, never as a state
- *resumability:* live / resumable / context-walled

Derived diagnoses: **PARKED** (idle or needs-input while it still owes work, i.e. a dropped baton) vs **HELD** (a deliberate wait with an armed wake). "Unknown beats a confident wrong answer."

**Remote:** a `hosts.yaml` registry with `transport: ssh` (runs the remote `rig` CLI) or `transport: http` (calls the remote daemon with a bearer token). `rig send … --host remote-dev`. It never silently falls back to the other transport.

**Reusable for you:** seat addressing (`role@group`), delivery leases plus readiness checks before injecting input, a durable group channel (chat) separate from the work queue, the PARKED/HELD idea for "who's stuck", and MCP tools as the way agents talk to the coordinator.

---

## 3. "Remux" (ambiguous name: several projects)

| Repo | What it is | Relevance |
|---|---|---|
| **[h3nock/remux](https://github.com/h3nock/remux)** ([getremux.app](https://getremux.app), ≈512★, TestFlight beta) | **Native iOS client for remote tmux workspaces**, built on **Ghostty's terminal core** (GhosttyKit) with **[Citadel](https://github.com/orlandos-nl/Citadel)** (Swift SSH). It attaches to tmux sessions, swipes between windows, shows a pane picker with live previews, has a shortcut palette with Claude Code and Codex presets, dictation, photo/file upload (the remote path is typed at the prompt), long-press to preview files and localhost URLs, direct SSH (no relay) and Keychain-stored keys. | **The best iOS reference for the remote-terminal half.** It proves a Ghostty plus Citadel stack works in an App Store-style app. |
| **[viminizer/remux](https://github.com/viminizer/remux)** | A single Go binary that embeds **`tsnet`** (a Tailscale node inside the process, with no tailscaled and no root) and a React PWA. **It never becomes a tmux client**: it uses only `capture-pane -t %id` and `send-keys -t %id`, and creates windows with `-d` so nothing resizes on the laptop. It refuses attach, resize, select and kill. Auth uses Tailscale `WhoIs` (no tokens), and every mutation goes to an audit log. A classifier writes pane user options `@remux_state` (`!` blocked, `✳` working, `✓` idle), `@remux_task` (3–5 words from a cheap model) and `@remux_project`. Measured: one capture-pane ≈11 ms; 29 panes captured in parallel ≈30 ms; 14 MB RSS. | **The best design reference for a companion daemon**: clientless tmux, tailnet identity auth, metadata in tmux user options. |
| [pzhxbz/remux](https://github.com/pzhxbz/remux) "RemoteMux" | A Rust agent on each machine dials *out* to a relay. A CLI and an Android app reach tmux through the relay (protocol v2). The author calls it an experimental vibe-coded project. | Reference for the relay/outbound-agent topology (useful when the hosts are behind NAT and not on the tailnet). |
| [camerondurham/remux](https://github.com/camerondurham/remux) | A cross-host index of live tmux panes over SSH (command, cwd, repo, activity), with capture and attach. No daemon. | A pattern for the "discover existing panes" registration flow. |
| [dnmfarrell/remux](https://github.com/dnmfarrell/remux), [swissyai/remux](https://github.com/swissyai/remux), [billiondollarsolo/remux](https://github.com/billiondollarsolo/remux), [johanhenriksson/remux](https://github.com/johanhenriksson/remux), [yaoshenwang/remux](https://github.com/yaoshenwang/remux) | Tiny (0–4★): a PTY plus WebSocket remote channel, a Rust agent supervisor, a session-persistence runtime, tmux plus worktrees, a Ghostty mac terminal. | Low signal. |
| [lostb1t/remux](https://github.com/lostb1t/remux) | A Jellyfin-compatible media server. | **Unrelated** (name collision). |

---

## 4. tmux internals that matter

Refs: [tmux wiki: Control Mode](https://github.com/tmux/tmux/wiki/Control-Mode), [tmux(1)](https://man.openbsd.org/tmux.1), [iTerm2 tmux integration](https://iterm2.com/documentation-tmux-integration.html).

- **Server/client.** A single server process per socket (`-L name` / `-S path`) owns every PTY. Clients are just views. Killing the SSH connection only kills the client, and the panes keep running. **This is the persistence layer you want on each remote host.** IDs: `$session`, `@window`, `%pane`. Always use IDs, not indexes.
- **Hierarchy.** server → sessions → windows → panes. Windows can be linked into several sessions. The `#{…}` format language plus `list-panes -a -F '#{pane_id} #{pane_current_command} #{pane_current_path} #{pane_pid} #{pane_activity} #{@agent_state}'` gives you a cheap whole-server inventory in one call.
- **Control mode (`tmux -CC attach -t s`).** Designed by George Nachman for iTerm2. It is a line protocol over stdin/stdout, so it works over plain `ssh host tmux -CC …`:
  - Each command reply is wrapped in `%begin <time> <cmdnum> <flags>` … `%end` or `%error`.
  - `%output %<pane> <octal-escaped bytes>` carries raw pane output. The client needs its own VT parser (SwiftTerm or Ghostty) per pane.
  - Notifications: `%window-add`, `%window-close`, `%layout-change`, `%session-changed`, `%sessions-changed`, `%pane-mode-changed`, `%exit`, and others.
  - **Flow control:** `refresh-client -f pause-after=N` switches to `%extended-output %pane <ms-behind> : data`, and slow panes get `%pause`. `refresh-client -A '%0:continue'`, `'%0:pause'`, or **`off`** (stop sending a pane you are not showing). Ideal for a grid where only the visible cells stream.
  - `refresh-client -f no-output` turns off all output, for a pure-metadata client.
  - **Format subscriptions:** `refresh-client -B name:%*:#{pane_current_command}…` sends `%subscription-changed` at most once per second. Cheap state polling done by the server.
  - `refresh-client -C WxH` sets the client size. **The gotcha:** a control client counts toward window sizing. Use `window-size latest` or `manual`, or `ignore-size` on the client (`attach -f ignore-size`, tmux ≥3.2) so the phone doesn't shrink the desktop layout. viminizer/remux avoids attaching altogether for this reason.
- **capture-pane.** `capture-pane -p -e -J -t %3 [-S -200 -E -]` snapshots the screen or scrollback (`-e` keeps the colours, `-J` joins wrapped lines). It is the basis of nearly every agent manager's state detection and previews. claude-squad, OpenRig and viminizer/remux all use it.
- **pipe-pane.** `pipe-pane -o -t %3 'cat >> ~/.mux/%3.log'` tees pane output to a command. Good for a durable transcript or log tail that a daemon can serve as an incremental byte offset ("give me bytes since offset N"). This is how the phone catches up after a reconnect without a full scrollback dump.
- **send-keys.** `send-keys -t %3 -l 'literal text'` followed by `send-keys -t %3 Enter`. `-H` takes hex for Unicode. For multi-line prompts use `load-buffer -` plus `paste-buffer -p -t %3` (bracketed paste), so TUIs like Claude Code treat newlines as part of the text instead of as submit.
- **User options.** `set -p -t %3 @agent_state blocked` stores arbitrary metadata on a pane. Format strings and subscriptions can read it, and it survives client detach. OpenRig (`@rigged_*`) and viminizer/remux (`@remux_*`) both use this.
- **Hooks.** `set-hook -g pane-exited`, `alert-activity`, `alert-silence` (`monitor-silence 30` fires "silent for N s", a crude idle signal), `pane-focus-in`, and others.
- **Persistence limits.** tmux survives disconnects, not reboots. tmux-resurrect and tmux-continuum ([tmux-plugins](https://github.com/tmux-plugins)) save and restore the layout. Agents come back via `claude --resume` or `codex resume` (Herdr's approach).
- **Windows.** No native tmux. Options: WSL2 tmux, [psmux](https://github.com/psmux/psmux) (a native Rust tmux clone for PowerShell, ≈3.6k★, ships a `tmux` command), or Herdr's native Windows server.

---

## 5. Zellij and web/remote terminal multiplexers

### Zellij ([zellij-org/zellij](https://github.com/zellij-org/zellij), ≈35.7k★, Rust)
- **Plugins** are WebAssembly (wasm32-wasi) with a permission system. They subscribe to events (`PaneUpdate`, `TabUpdate`, `SessionUpdate`, …), can run commands and web requests, and get `pipe` messages from the CLI. Docs: [plugins](https://zellij.dev/documentation/plugins.html).
- **CLI actions** ([cli-actions](https://zellij.dev/documentation/cli-actions.html)): `zellij action write-chars`, `write`, `send-keys`, `paste`, `dump-screen [--full] --pane-id terminal_3`, `list-panes --json`, with `ZELLIJ_PANE_ID` in the environment. Scriptable like tmux, but without a control-mode stream.
- **Session resurrection** ([docs](https://zellij.dev/documentation/session-resurrection.html)): layout and commands are serialized by default. Viewport and scrollback serialization is optional. Resurrected commands wait behind a "Press ENTER to run…" banner (an anti-`rm -rf` safety idea worth copying for agent auto-resume). `post_command_discovery_hook` fixes up commands detected through wrappers.
- **Web client** ([docs](https://zellij.dev/documentation/web-client.html)): `zellij web`, off by default. Login tokens are stored hashed and shown once. HTTPS is mandatory off-localhost. URL `/<session-name>` attaches, creates or resurrects, so a bookmark always gets you back.

### Others
| Tool | Model | Notes for you |
|---|---|---|
| **ttyd** ([tsl0922/ttyd](https://github.com/tsl0922/ttyd), ≈12.5k★) | One command (e.g. `tmux new -A -s agents`) shared over a WebSocket with xterm.js. Read-only by default; `-W` makes it writable. | A trivially simple binary protocol: client→server `'0'`input `'1'`resize-JSON `'2'`pause `'3'`resume `'{'`init-JSON; server→client `'0'`output `'1'`title `'2'`prefs. Flags: `-c user:pass`, `-O` origin check, `-P` ping, TLS. Running ttyd wrapped around `tmux attach -t %pane` gives you one cheap WebSocket endpoint per agent. |
| **sshx** ([ekzhang/sshx](https://github.com/ekzhang/sshx), ≈7.7k★) | A web-based collaborative terminal on an infinite canvas, through a relay mesh. | E2E encryption (Argon2 plus AES), automatic reconnect, latency estimates, **mosh-style predictive echo**. A good UX reference for a grid of terminals. |
| **tmate** ([tmate-io/tmate](https://github.com/tmate-io/tmate)) | A fork of tmux that shares the session through tmate.io (or a self-hosted server) over SSH. | Instant share links; read-only and read-write tokens. |
| **upterm** ([owenthereal/upterm](https://github.com/owenthereal/upterm), ≈1.3k★) | Reverse-SSH terminal sharing through `uptermd`. | `--authorized-keys` / `--authorized-user github:me` is a nice model for authorizing via public keys. |
| **WezTerm mux** ([wezterm.org/multiplexing](https://wezterm.org/multiplexing.html)) | `wezterm-mux-server` with Unix, SSH and TLS domains. The GUI attaches to a remote mux and reconnects. | A different take: the mux protocol is native to the terminal emulator. Not usable from iOS. |
| [lamngockhuong/termote](https://github.com/lamngockhuong/termote) | A Go PWA that streams tmux, psmux or Herdr panes to a phone. | Shows that tmux, psmux and Herdr can share one backend abstraction. |

---

## 6. Agent-specific managers (2025–2026)

| Tool | Architecture / isolation | State detection | I/O | Grouping | Remote |
|---|---|---|---|---|---|
| **claude-squad** ([smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad), ≈8.6k★, Go, `cs`) | Bubble Tea TUI. Each instance is a **tmux session plus a git worktree**. A daemon handles `--autoyes`. | `session/tmux/tmux.go`: `capture-pane -p -e -J`, **sha256 of the content compared with the previous tick** (changed means working), plus **literal prompt strings** ("No, and tell Claude what to do differently", "Yes, allow once", aider's `(Y)es/(N)o`). Also auto-dismisses the trust prompt. | Attaches to the tmux PTY; send-keys. | A flat list; diff and commit per instance. | Local only. |
| **agent-deck** ([asheshgoplani/agent-deck](https://github.com/asheshgoplani/agent-deck), ≈1k★, Go) | A TUI over tmux sessions, with a web UI (`agent-deck web` :8420). | "Smart polling" into running / **waiting** / idle / error, shown in the tmux status bar (`Ctrl+b 1–6` jumps to waiting sessions). | tmux. | **Hierarchical groups** (`projects/devops`), declared in `config.toml` with per-group `default_path`, env_file and `CLAUDE_CONFIG_DIR`. `M` moves a session to a group. | **Remote decks** over SSH. The **Conductor** pattern: a conductor Claude session watches its children, a notify-daemon nudges the parent on `running→waiting`, and a Telegram/Slack/Discord bridge plus webhook/GitHub watchers wake it. Also fork sessions, a per-session MCP manager, and worktree hook approval bound to sha256. |
| **Conductor** ([conductor.build](https://www.conductor.build), Melty Labs, closed source) | A Mac app that runs first-party Claude Code, Codex, Cursor and OpenCode agents in isolated workspaces (git worktrees). Now has **Conductor Cloud** (Firecracker microVM per agent), an **iOS app** (v0.90.0, 2026-10-02), an API and multiplayer workspaces. | Proprietary. | Its own chat UI on top of the agents' SDK/JSON modes. | Workspaces per repo. | Cloud plus iOS. A product reference, not reusable code. (Unrelated GitHub repos named "conductor" are spec-driven-dev plugins.) |
| **Crystal → Nimbalyst** ([stravu/crystal](https://github.com/stravu/crystal), ≈3.1k★, Electron) | Parallel Claude Code and Codex sessions in git worktrees. **The project is now [Nimbalyst](https://github.com/Nimbalyst/nimbalyst).** | Agent JSON or SDK events. | — | Sessions per project. | Local. |
| **Vibe Kanban** ([BloopAI/vibe-kanban](https://github.com/BloopAI/vibe-kanban), ≈28k★, Rust plus React, `npx vibe-kanban`) | Kanban issues → **workspaces** (branch plus terminal plus dev server). Supports 10+ agents, inline diff comments fed back to the agent, PR creation, a self-hostable cloud. | Executor processes in structured/JSON modes. | — | Board / issue. | Web UI; self-host. |
| **uzi** ([devflowinc/uzi](https://github.com/devflowinc/uzi), ≈580★, Go, inactive since 2025-06) | tmux session plus worktree per agent, a dev server port range (`uzi.yaml`), checkpoint/merge. | Monitoring plus **auto-handling of prompts**. | tmux send-keys. | — | Local. |
| **Sculptor** ([imbue-ai/sculptor](https://github.com/imbue-ai/sculptor), ≈240★) | A desktop app; each workspace is an isolated copy of the code (originally containers); bundled skills. | — | — | Workspaces. | Local. |
| **cmux** ([manaflow-ai/cmux](https://github.com/manaflow-ai/cmux), ≈28k★) | A Ghostty-based macOS terminal with vertical tabs and **notifications for agents**, plus a socket API. OpenRig supports it as a viewer. | Agent notifications (OSC/hooks). | — | Tabs/workspaces. | Mac. |
| **Happy** ([slopus/happy](https://github.com/slopus/happy), ≈24k★, MIT) | `happy claude` / `happy codex` wraps the CLI. **E2E-encrypted relay** to iOS, Android and web; multiplayer. | Structured agent events. | The mobile app sends messages into the wrapped session. | Sessions. | Relay (self-hostable). |
| **Paseo** ([getpaseo/paseo](https://github.com/getpaseo/paseo), ≈20k★) | A **daemon** per machine manages the agents. Clients on desktop, iOS, Android, web and CLI connect directly over TCP or **Tailscale**, or through an optional E2E relay. Agents in Paseo can create worktrees, **launch other agents and talk to them across providers**. Plugins run on the daemon and show up in every client. | Provider adapters. | — | Workspaces/worktrees. | Multi-host. **Architecturally the closest to your target.** |
| **CloudCLI / claudecodeui** ([siteboon/claudecodeui](https://github.com/siteboon/claudecodeui), ≈14k★) | A web/mobile UI over Claude Code, Cursor, Codex and OpenCode session files plus processes. | Session files. | — | Projects. | Web. |
| **agentapi** ([coder/agentapi](https://github.com/coder/agentapi), **deprecated/archived**) | An HTTP wrapper around any TUI agent: `/message`, `/messages`, `/status` (stable/running), `/events` SSE. **An in-memory terminal emulator; the screen is snapshotted before input and diffed afterward to pull out the reply.** | Snapshot stability. | Keystrokes. | — | Good algorithm reference. |
| Others seen | [stablyai/orca](https://github.com/stablyai/orca) (ADE, desktop, mobile and remote), [BennyKok/omg.dev](https://github.com/BennyKok/omg.dev) (remote control with a mobile client), [no1msd/seance](https://github.com/no1msd/seance) (scrolling multiplexer that tracks agents), [eneskirca/nodeterm](https://github.com/eneskirca/nodeterm) (tmux-backed canvas), [termio-sh/termio](https://github.com/termio-sh/termio), [y49/tlive](https://github.com/y49/tlive) (remote approvals via Telegram or a web terminal), [QuivrHQ/247-claude-code-remote](https://github.com/QuivrHQ/247-claude-code-remote) (Tailscale), [artyomsv/quil](https://github.com/artyomsv/quil), [omnara-ai/omnara](https://github.com/omnara-ai/omnara). | | | | |

**Agent-native structured modes (to prefer over scraping):**
- **Codex app-server** ([docs](https://developers.openai.com/codex/app-server), source `openai/codex/codex-rs/app-server`): JSON-RPC 2.0 without the `jsonrpc` field. Transports: `stdio://` (JSONL, the default), `unix://`, `ws://IP:PORT` (experimental), with `--ws-auth capability-token --ws-token-file …` or signed bearer tokens. It sends `initialize`, then `thread/start` and `turn/start` (plus steering to append to an in-flight turn), and streams `turn/started`, `item/started`, `item/completed`, `item/agentMessage/delta`, `turn/completed`. Server→client requests cover **approvals**, `item/permissions/requestApproval` and MCP elicitation. `codex --remote ws://…` attaches the real TUI to a remote app-server, which is a *native* way to share one Codex thread between a TUI and your app. `generate-ts` and `generate-json-schema` produce version-matched schemas.
- **Claude Code** ([headless](https://code.claude.com/docs/en/headless), [hooks](https://code.claude.com/docs/en/hooks), [remote-control](https://code.claude.com/docs/en/remote-control)):
  - `claude -p --output-format stream-json --verbose --include-partial-messages` gives NDJSON events with `session_id`. `--input-format stream-json` lets you feed several user messages over stdin. `--resume <id>` / `--continue` pick a session back up.
  - **Hooks** (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `Notification` with matchers like `permission_prompt` / `idle_prompt`, `Stop`, `SubagentStop`) give you exact working, blocked and idle transitions. The hook calls your reporter, the same idea as Herdr's integration.
  - **Remote Control** (`claude --remote-control`) syncs a local session to the Claude iOS app and claude.ai. It needs a subscription and goes through Anthropic, so it can't be used from your app.
  - The Claude Agent SDK is another option.

---

## 7. iOS mobile clients and the network layer

- **Blink Shell** ([blinksh/blink](https://github.com/blinksh/blink), GPLv3): an iOS terminal built around **mosh** plus SSH; its docs cover a [Tailscale + Mosh integration](https://docs.blink.sh). **Mosh** ([mosh.org](https://mosh.org)) runs `mosh-server` over UDP with **SSP (State Synchronization Protocol)**. Because the session is bound to a key and not to an IP/TCP connection, it **roams** across Wi-Fi and cellular and survives sleep. Predictive local echo hides latency. The catch: mosh syncs **screen state, not a byte stream**, so there is no scrollback. That's why people run `mosh host -- tmux new -A -s main`. On iOS, Blink keeps the mosh state client-side, and it resumes on foreground as long as the server's UDP session hasn't timed out.
- **Termius**: a commercial cross-platform SSH client (iOS included) with synced hosts and keys, snippets, port forwarding and, I believe, mosh support. Closed source.
- **h3nock/remux** (§3): Ghostty plus Citadel, built for tmux.
- **Clauntty** ([eriklangille/clauntty](https://github.com/eriklangille/clauntty), ≈400★): an iOS SSH terminal (Ghostty Metal renderer) that **auto-deploys a tiny `rtach` binary** to the server. That gives persistent sessions with scrollback replay, plus a "battery-optimized pause/resume protocol". In other words, a **minimal companion daemon pushed over SSH on first connect**. A strong pattern for you.
- **Claude iOS app plus Remote Control**, **Conductor iOS**, **Happy**, **Paseo**, **herdr-web-ui PWA**, **CloudCLI**: agent-level (chat-style) mobile clients. Lesson from all of them: on a phone, **chat plus approval cards beat raw terminals**, with the terminal kept one tap away.
- **Tailscale SSH** ([kb/1193](https://tailscale.com/kb/1193/tailscale-ssh)): tailscaled answers port 22 on the tailnet IP and authenticates by **tailnet identity** plus ACLs (no keys to manage). It distributes host keys, has "check mode" re-auth (12 h by default), and supports session recording. **The server side works only on Linux and on macOS with the open-source tailscaled.** A **Windows** desktop needs regular OpenSSH Server, reached over the tailnet IP, with key auth. Tailscale itself (WireGuard) roams well: the underlying UDP path re-establishes when the phone changes networks. TCP sessions on top survive short changes, but **iOS suspends the app's sockets in the background**, so reconnect logic is mandatory.
- **tsnet** ([kb/1244](https://tailscale.com/kb/1244/tsnet)): embeds a Tailscale node in a Go program, so a companion daemon is reachable at `https://name.<tailnet>.ts.net` without tailscaled, and can call `WhoIs` for auth (viminizer/remux does this).
- **iOS constraints** (platform knowledge, not taken from the sources above): no long-lived background sockets. A `beginBackgroundTask` gives you roughly 30 s. BGAppRefresh/Processing tasks are opportunistic and short. **Push (APNs) is the only reliable wake-up**, and the app can't push to itself, so the *remote* side (daemon, relay, or ntfy/Telegram/web push) has to send "agent blocked" notifications. **The remote side holds all state, and the phone reattaches when it comes to the foreground.**

---

## 8. Design concept: "Mux" for the OpenMinis fork

### 8.1 Context in OpenMinis (verified in [OpenMinis/OpenMinis](https://github.com/OpenMinis/OpenMinis), GPLv3)
- Slash commands are dispatched in `src/ios/Agent/Chat/AIChatViewModel+SlashCommands.swift`. Built-ins (`clear`, `compact`, `memory`, `thinking`) are `SlashCommand(id:icon:title:subtitle:)` rows handled in a `switch cmd.id`. A `/mux` case goes there.
- The on-device terminal stack is `src/ios/iSH/Terminal/{TerminalEmulator,ANSIParser,TerminalBuffer,TerminalCanvasView}.swift` plus `Views/Rootfs/ISHTerminalView.swift`. You can reuse it to render remote pane bytes, or swap in SwiftTerm or GhosttyKit for full fidelity.
- Existing building blocks: `minis-sessions-cli` (list, messages, send, status), `minis-scheduled`, the sub-agent infra (`SubAgentStore`, sub-agent lifecycle), MCP via `minis-mcp-cli`, and the shared directory `/var/minis/shared`.

### 8.2 Data model
```swift
struct MuxGroup: Identifiable, Codable {
  let id: UUID; var name: String; var icon: String?
  var members: [MuxMemberRef]            // ordered → grid order
  var channel: GroupChannelConfig        // shared blackboard / chat
  var policy: GroupPolicy                // who may message whom, auto-approve rules, quiet hours
  var layout: GridLayout                 // .list | .grid(columns) | .focus(memberId)
}

struct MuxMemberRef: Codable { let endpointId: UUID; var role: String?  /* "lead","builder","reviewer" → addressable as role@group */ }

struct AgentEndpoint: Identifiable, Codable {
  let id: UUID; var displayName: String; var hostId: UUID?   // nil = on-device
  var kind: EndpointKind
  var capabilities: Set<Capability>      // .rawTerminal, .structuredChat, .approvals, .resume, .stateReports
  var lastState: AgentState; var lastSeen: Date; var resume: ResumeSpec?
}

enum EndpointKind: Codable {
  case localSession(chatSessionId: String)                         // in-app Minis chat (+ its iSH shell)
  case localShell(ishPaneId: String)                              // optional: plain iSH terminal
  case tmuxPane(socket: String?, session: String, paneId: String)  // "%14", via SSH (+ -CC) or companion
  case herdrPane(machine: String, paneId: String)                  // "w1:p2" via herdr socket API
  case codexAppServer(url: URL, threadId: String?)                 // JSON-RPC
  case claudeStreamJSON(sessionId: String, cwd: String)            // spawned/managed by companion
  case companion(agentId: String)                                  // generic: daemon-managed agent
}

struct Host: Identifiable, Codable {
  let id: UUID; var label: String; var os: OSKind                  // .linux, .macos, .windows
  var address: String                                              // MagicDNS name / 100.x
  var transports: [HostTransport]                                  // ordered preference
  var authRef: KeychainRef                                         // SSH key / token in Keychain
  var hostKeyPin: String?
}
enum HostTransport: Codable { case sshTmuxCC, sshExec, companionWS(port: Int), herdrOverSSH, ttydWS(URL) }

enum AgentState: String, Codable { case working, blocked, done, idle, unknown, disconnected, exited }
struct Attention: Codable { var count: Int; var reason: String?; var promptId: String? }  // OpenRig-style needs-input

struct PaneView { let endpointId: UUID; var mode: PaneMode /* .preview(lines:12) | .live | .chat */; var isStreaming: Bool }
```
`AgentState` copies Herdr's vocabulary, with `disconnected` added for transport loss. The `Attention` struct copies OpenRig's rule that needs-input is a count plus a reason, never a state. Keep **unknown** as a legitimate value.

### 8.3 UI (matching the request)
1. **Groups pane** (sidebar, or the root list on iPhone): each row shows the group name, rolled-up state dots (worst first: blocked > working > done > idle), an attention badge and the hosts involved.
2. **Group view**: a scrolling `LazyVGrid` / `LazyVStack` of **pane cards**. Each card has a header (agent, host, state, task label), a live mini-terminal or the last N lines, and an inline composer ("type into this agent"). Off-screen cards stop streaming (control mode `-A '%id:off'` or a daemon unsubscribe) and show the last snapshot. A "needs you" filter sits on top.
3. **Tap card → full session**: a local endpoint opens the existing Minis chat. A remote one opens a full terminal (key bar: Esc, Tab, Ctrl, arrows) or a **chat view** if the endpoint has `.structuredChat` (Codex app-server or Claude stream-json, or a transcript read like herdr-web-ui does). Approval requests show as cards whose prompt id is re-checked before the answer is sent.
4. **Group channel** tab: a shared message log (see §8.6).
5. **Slash commands** (in `executeSlashCommand`):
   - `/mux add [group] [role]` registers the *current* chat session as `localSession`.
   - `/mux attach <host> [%pane|w1:p2]` adopts a remote pane, with a picker built from `list-panes -a -F …` (camerondurham/remux style).
   - `/mux new <host> <agent> [cwd] [--worktree]` spawns remotely (`tmux new-window -d …`, or companion spawn).
   - `/mux send <role@group> <msg>`, `/mux status`, `/mux leave`.
   - Also expose these as a CLI inside iSH (`minis-mux …`) so *agents* can use them (Herdr's agent-skill idea).

### 8.4 Transport options for off-device agents

| Option | How | Pros | Cons | Use when |
|---|---|---|---|---|
| **A. SSH + `tmux -CC`** | Citadel or NIOSSH exec channel `tmux -CC attach -f ignore-size,read-only? -t agents`; parse `%output` and notifications; `pause-after` flow control; `-B` subscriptions for state options | Zero install beyond tmux; real-time byte stream; structured events; iTerm2-proven | Needs a VT parser per pane; size negotiation (use `ignore-size`, set `window-size manual`); one exec channel per session; Windows needs WSL or psmux | **MVP for Linux/macOS hosts** |
| **A′. SSH clientless polling** | `capture-pane -p -e -J` plus `send-keys`/`paste-buffer` per pane, batched in one `ssh … sh -c` | Never touches the desktop layout (viminizer); dead simple; great for previews | Polling (1–2 s); no true stream | Grid previews, low battery, Windows/psmux |
| **B. ttyd / WebSocket per pane** | `ttyd -W -i 127.0.0.1 tmux attach -t %id` behind tailnet/`tailscale serve` | Trivial protocol; works with `WKWebView` + xterm.js | One process per pane; tmux-attach resize issue; weak auth unless fronted | Quick full-terminal view |
| **C. Agent JSON/RPC** | Codex `app-server --listen unix://` (forwarded over SSH, or via the companion); Claude `-p --input/--output-format stream-json` run by the companion; hooks for state | Exact state, approvals as data, chat UI, no scraping | Agent-specific; for Claude, the stream-json session is a separate headless process, not the TUI the user sees on the desktop (Codex `--remote` *can* share one thread between the TUI and your app) | Rich chat/approvals for Codex/Claude |
| **D. Herdr as the backend** | SSH-exec `herdr`'s CLI or a socket bridge (`ssh host herdr api …`, or the NDJSON socket through `ssh -L`/stdio) | Detection, persistence, resume and **Windows server** done for you; huge client ecosystem | A dependency on Herdr's evolving API; must speak its remote protocol or bridge the socket | Hosts that already run Herdr |
| **E. Companion daemon (`muxd`)** | A small Go/Rust binary per host (tsnet-embedded optional): wraps tmux/psmux/Herdr; spawns agents in structured modes; keeps ring buffers, transcripts and a state machine; serves WS/NDJSON; sends push | Holds state while the phone sleeps; incremental replay by offset; push notifications; one protocol across OSes; group-channel relay between hosts | Something to install and update (mitigate with Clauntty-style auto-deploy over SSH) | **Full version** |

**Recommended progression:** A′ (previews) plus A (live focus pane) for the MVP. Then C for Codex and Claude. Then E as the unifying layer, with D as an alternative backend type.

**Suggested companion wire protocol** (NDJSON over a WebSocket, Herdr-like):
```
→ {"id":1,"method":"hello","params":{"client":"minis","resume_token":"…"}}
← {"id":1,"result":{"host":"desk-win","epoch":7,"agents":[…snapshot…]}}
→ {"id":2,"method":"subscribe","params":{"agents":["a3","a7"],"from_offset":{"a3":918233}}}
← {"event":"output","agent":"a3","offset":918240,"data_b64":"…"}
← {"event":"state","agent":"a7","state":"blocked","attention":{"count":1,"reason":"permission prompt","prompt_id":"p19"},"seq":1791..}
→ {"id":3,"method":"input","params":{"agent":"a7","text":"yes","submit":true,"expect_prompt_id":"p19"}}
→ {"id":4,"method":"channel.post","params":{"group":"g1","from":"minis:chat-42","body":"…"}}
```
Key properties: **snapshot then subscribe**; **byte offsets** (pipe-pane logs or ring buffers) so a reconnect replays only the gap; **monotonic `seq`** on state; and **`expect_prompt_id`** so a stale tap never answers the wrong prompt (herdr-web-ui and OpenRig both do some form of this).

### 8.5 State detection (layered, highest confidence first)
1. **Self-report or structured**: Codex app-server events; Claude hooks (`UserPromptSubmit`/`PreToolUse` → working, `PermissionRequest`/`Notification(permission_prompt)` → blocked, `Stop`/`Notification(idle_prompt)` → idle/done) POSTing to the companion or setting `tmux set -p @agent_state`; any agent that already reports to Herdr. For in-app Minis sessions, the agent loop knows its state exactly: streaming → working, awaiting a tool permission → blocked, finished → done.
2. **Screen manifests**: regexes on the live bottom N lines (`capture-pane -p -S -15`), per agent: claude-squad's strings, Herdr's manifests, spinners and timers for working.
3. **Activity heuristics**: content hash change between ticks (claude-squad), tmux `#{pane_activity}` / `monitor-silence`, foreground process (`#{pane_current_command}` back to a shell means exited).
4. Otherwise **unknown**. Never guess "blocked"; it triggers notifications.

Keep a `done` vs `idle` "seen" bit on the phone (Herdr). Roll up per group with worst-wins ordering.

### 8.6 Mixed on/off-device groups and cooperation
- **Addressing:** `role@group` (OpenRig). Every member gets a stable `endpointId` plus an optional role.
- **Group channel (blackboard):** an append-only log (`{ts, from, to?, kind: note|task|result|question, body, refs}`). Two equivalent storage choices:
  - (a) **Phone-authoritative:** `/var/minis/shared/mux/<group>/channel.jsonl`, mirrored to each host's companion (`~/.muxd/groups/<g>/channel.jsonl`) when connected.
  - (b) **Host-authoritative** (better, since the phone sleeps): one "home host" companion keeps the canonical log, and the phone plus other hosts sync. Use (b) once the companion exists.
- **Delivery into agents:**
  - *Remote terminal agents:* the companion types the message in under a **per-agent delivery lease**, but only when `state ∈ {idle, done}`, or queues it ("held") when the agent is blocked or the human is typing (OpenRig's `target_needs_input` and typing guard). Use bracketed paste via `paste-buffer -p`.
  - *Structured agents:* `turn/start` (Codex) or a stream-json user message (Claude).
  - *Local Minis agent:* reuse `minis-sessions-cli send` (or an in-process API) to post into the chat session as a user or system message tagged `[from builder@g1]`.
- **Agent-initiated messaging:** give every member the same **MCP server**, `mux-mcp` (served by the companion over stdio for remote CLIs, and registered via `minis-mcp-cli` for the in-app agent). Tools: `mux_list_members`, `mux_read(member, lines)`, `mux_send(to, body)`, `mux_post(channel, body)`, `mux_wait(member, until)`, `mux_task_claim/close`. These map to Herdr's `agent.prompt` / `agent.wait` and OpenRig's `rig_send` / `rig_chatroom_*`. Low-tech fallback: a shell CLI (`muxctl`) plus a skill file explaining it (`HERDR_ENV`-style `MUX_ENV=1`, `MUX_MEMBER_ID`, `MUX_GROUP`, `MUX_SOCKET`).
- **Work vs chat:** keep a separate tiny **task queue** per group (pending / in-progress / blocked / done / handed-off) so "who owes what" survives restarts. "PARKED" = idle while owning an open task. Surface it in the UI.
- **Coordinator pattern:** the in-app Minis agent can act as group **lead or conductor** (agent-deck Conductor, herdr-projects coordinator). It reads the channel, assigns tasks via `mux_send`, and is woken by companion push or `minis-scheduled` follow-ups.

### 8.7 Persistence and reconnect over Tailscale
- **The remote holds the truth:** tmux, Herdr or the companion keeps the processes, scrollback ring buffers (or pipe-pane logs), the state machine and the group channel. The phone stores only the endpoint registry, the last snapshot and the last offsets (Core Data or JSON in app storage).
- **On `scenePhase == .active`:** for each host in visible groups, reconnect with exponential backoff and jitter, call `hello` with a `resume_token`, get the snapshot, then `subscribe from_offset`. With SSH and `-CC`, re-run `tmux -CC attach` and then `capture-pane` the visible panes to repaint (control mode doesn't replay history).
- **On background:** send unsubscribe or `off`, close cleanly within the `beginBackgroundTask` window, and persist offsets.
- **Notifications while backgrounded:** the companion sends push (APNs needs your own relay, since the provider key can't live on hosts securely; simpler options are **ntfy**, Pushover, Telegram, or a self-hosted APNs relay) on `→blocked` and `→done` transitions, with a deep link `minis://mux/group/<g>/agent/<id>`.
- **SSH specifics:** keepalive (`ServerAliveInterval` equivalent in Citadel/NIO), host-key pinning, keys in the Secure Enclave or Keychain. Tailscale's WireGuard roaming handles network changes. TCP may still die, so the reconnect has to be idempotent. mosh isn't needed once you have offset-based replay.
- **Windows desktop:** OpenSSH Server over the tailnet IP (Tailscale SSH server isn't supported on Windows). Backend choice: WSL2 tmux (agents run in WSL), or [psmux](https://github.com/psmux/psmux) (native tmux-compatible CLI, but no `-CC` assumed, so use A′ polling), or **Herdr's native Windows server**, or the companion managing ConPTY directly.

### 8.8 Security
- **Treat a host connection as remote code execution.** Every member can type into shells that have filesystem and network access.
  - Use tailnet ACLs restricting the phone's identity to specific hosts and ports.
  - Bind the companion to the tailnet only (tsnet or tailscale IP) and never to Funnel or 0.0.0.0.
  - Authenticate with Tailscale `WhoIs` (viminizer) **and** a per-device capability token (Codex `--ws-auth capability-token` style), stored hashed.
- **Least privilege:** a dedicated user per host; a companion command allow-list (refuse `kill-server`, resize and attach like viminizer); `read-only` attach mode for previews.
- **Audit log** of every injected input (who, target, bytes hash), on both phone and host.
- **Injection safety between agents:**
  - Messages from other agents are **untrusted data**. Wrap them (`<mux-message from="builder@g1">…</mux-message>`) and tell agents not to follow instructions that escalate permissions.
  - No automatic approval of permission prompts across agents by default. Approvals require a human tap, or an explicit per-group policy (e.g. auto-approve only read-only tools).
  - Rate-limit agent→agent sends to prevent loops.
- **Prompt-race guard:** `expect_prompt_id` / state-seq checks before sending "y" or "Enter".
- **Secrets:** pane history can contain tokens. Keep scrollback persistence opt-in (Herdr's default) and encrypted at rest on the phone; redact obvious tokens in previews.
- **Resume safety:** after a restart, put resumed agent commands behind "tap to resume" (Zellij's "Press ENTER to run" idea).
- **Supply chain:** pin and verify the companion binary hash when auto-deploying over SSH (Clauntty/rtach pattern); sign releases.

### 8.9 Incremental build plan
| Phase | Scope | Deliverable / acceptance |
|---|---|---|
| **0. Spike** (1–2 wk) | Citadel (or SwiftNIO-SSH) in the fork; connect over Tailscale to a Linux box; run `tmux list-panes -a -F`; render `capture-pane -e` output in the existing `TerminalEmulator`. | You can see a remote Claude Code pane on the phone. |
| **1. MVP "local groups + remote previews"** | Group/Endpoint/Host model and persistence. `/mux add` registers the current chat; `/mux attach` uses the pane picker. Grid with 1–2 s `capture-pane` polling (A′). Inline composer via `send-keys -l` / `paste-buffer -p`. Tap → full Minis chat (local) or full-screen terminal (remote, still polling). Screen-manifest state for Claude/Codex plus exact state for local sessions. | Mixed group of 1 local plus N remote agents; type into any; state dots roll up. |
| **2. Live streaming** | `tmux -CC` per host with `ignore-size`; the focused card streams `%output` while off-screen panes are `off`; `pause-after` flow control; `-B` subscriptions on `@agent_state`; foreground reconnect plus capture repaint. | Smooth live terminal; no desktop resize; reconnects in under 2 s on foreground. |
| **3. Hooks & structured agents** | Install hook snippets (Claude `settings.json` hooks → `tmux set -p @agent_state …`); Codex app-server endpoint (over an SSH-forwarded unix socket) with chat view and approval cards; resume specs (`claude --resume`, `codex resume`). | Reliable blocked/idle; approve from the phone; chat view for Codex/Claude. |
| **4. Group channel + MCP** | `channel.jsonl` blackboard; `mux-mcp` for the in-app agent (via `minis-mcp-cli`) and remote CLIs (over SSH stdio); delivery leases and held messages; role addressing; simple task queue and PARKED view. | Local Minis lead assigns tasks to a remote Claude and a Codex; results flow back to the channel. |
| **5. Companion daemon `muxd`** | Go binary with tsnet; wraps tmux/psmux/Herdr; ring buffers and offsets; NDJSON/WS protocol (§8.4); push via ntfy or an APNs relay; auto-deploy over SSH with hash pinning; Windows support (ConPTY or psmux); host-authoritative channel and cross-host relay. | Phone can sleep for hours; push on block; instant catch-up; Windows desktop first-class. |
| **6. Full** | Herdr backend adapter; worktree spawn (`/mux new --worktree`); conductor mode (in-app agent wakes on push or `minis-scheduled`); multi-device (iPad split view); policy engine (auto-approve rules, quiet hours); transcript search across the group. | Feature parity with agent-deck/Herdr clients plus a unique on-device agent member. |

### 8.10 Open questions / assumptions
- I assumed the remote CLIs run in tmux, or can be moved into it. Agents started in a bare Windows console can't be adopted later. They have to be launched under the multiplexer, Herdr or the companion.
- Claude's stream-json mode is a *separate headless process*: it can't share the exact TUI conversation a human is using at the desk. Codex `--remote` can share one. For Claude, keep the terminal path (tmux plus hooks) as the shared surface, or read its transcript files (herdr-web-ui's approach) for a chat view.
- Herdr's remote wire protocol (as opposed to its documented local socket) isn't documented as a public API. Bridging its local NDJSON socket over SSH (`ssh host socat - UNIX-CONNECT:~/.config/herdr/herdr.sock`) is the safer integration. That's my inference; check it on a test host.
- App Store review: shipping an SSH client is fine (Blink, Termius and Remux all do it). Auto-deploying binaries to *your own* servers is fine. Avoid downloading executable code into the app itself.
