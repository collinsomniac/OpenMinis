# Mux — the agent multiplexer for Nabla (design brief, pre-implementation)

The goal: one place to see and steer many agents, both on the phone and on other machines. Agents are
organized into groups. Each group shows a scrolling grid of live terminals. You can type into any agent
from the grid, or jump to its full session, and agents on different machines in the same group can work
together.

This brief folds together two research reports and the parts of our own codebase they plug into:
- `/var/minis/shared/research/multiplexer/MULTIPLEXER-RECON.md` (Herdr, OpenRig, Remux, tmux control mode,
  claude-squad, agent-deck, iOS clients)
- `/var/minis/shared/research/harness-review/HARNESS-REVIEW.md` (Pi, Hermes, Claude Code, Codex,
  DeepSeek `dsh`, OpenCode, Goose, Gemini CLI)

Status: research complete, nothing built. Every decision below is open for the user to change.

---

## 1. What exists and what we copy

| project | what it is | what we take |
|---|---|---|
| **Herdr** (`herdrdev/herdr`, Rust, ~43k★) | A tmux-like server and client built for coding agents. Organised as workspaces → tabs → panes. Every pane carries a state (`working / blocked / done / idle / unknown`). Several SSH machines appear in one sidebar, including Windows. Only the machine you're looking at sends terminal output; the others send just their status. Has a JSON socket API. | The **state vocabulary**. The "only the focused host streams" bandwidth rule, which is exactly right for a phone. The rule that agents and hooks report their own state, and that this beats reading the screen. A possible backend adapter. |
| **OpenRig** (`mvschwarz/openrig`, TS, ~7k★) | A coordination daemon with SQLite. Its rule is "tmux is transport, not truth". Agents get addresses by role. It locks each agent's input, refuses to type into an agent that is showing a prompt, keeps a durable group chat and task queue, and runs an MCP server. | The **cooperation model**: a group channel, a task queue, role addressing, the prompt-race guard, and MCP tools for agents. |
| **h3nock/remux** | A native iOS tmux client built on Ghostty, using Citadel for SSH. | The **iOS terminal and SSH stack** reference. |
| **viminizer/remux** | A Go binary with Tailscale (tsnet) built in, plus a phone web app. It uses only `capture-pane` and `send-keys` and never attaches as a client, so it never resizes the desktop layout. It authenticates callers by their Tailscale identity. | **Non-intrusive polling**, used for the grid. **Tailscale identity** as the authentication. |
| **tmux `-CC` control mode** | Structured output over plain SSH: `%output` events, flow control with `pause-after`, the ability to turn off panes you aren't showing, and format subscriptions. | **Live streaming for the pane in focus.** Must be used with `ignore-size`. |
| **Codex app-server / Claude Code stream-json and hooks** | Machine protocols for driving and observing an agent. | **Exact agent states and approval requests**, with no screen reading needed. |

## 2. Where it lives in the app (verified)

- **Entry point.** The top-right toolbar has a `Menu` behind the terminal icon. It is defined in `Views/ContentView.swift` around the `ToolbarItem(placement: .topBarTrailing)` that renders `Image(uiImage: Self.terminalCircleIcon)`. It currently holds Shell Terminal (`showTerminal = true`), Rootfs Management, Open Browser and Browser Settings. Two options:
  - **(a)** add a separate Mux toolbar button beside it (what the user asked for). The layout comment notes that the trailing toolbar already carries the alarm and terminal buttons, so space on iPhone is tight.
  - **(b)** make Mux the first entry in that same menu.
  - Recommendation: **(a) on iPad, (b) on iPhone**, both routing to the same `activeToolSheet = .mux` case.
  - Sheets are routed through `enum ToolSheet` (`ContentView.swift:1166`).
- **Slash command.** `Agent/Chat/AIChatViewModel+SlashCommands.swift` has `static let availableSlashCommands` (currently `clear`, `compact`, `memory`, `thinking`) and handles them in a `switch cmd.id`. `/mux` gets added there.
- **Terminal rendering.** `src/ios/iSH/Terminal/{TerminalEmulator, ANSIParser, TerminalBuffer, TerminalCanvasView}.swift` plus `Views/Rootfs/ISHTerminalView.swift`. Bytes from a remote pane can go straight into the existing emulator.
- **Local agents.** In-app chat sessions are the on-device members. `minis-sessions-cli` (list, messages, send, status) already gives an agent programmatic access to sessions, so a "local endpoint" is a session id.
- **Cooperation primitives.** The sub-agent system (`SubAgentStore`), MCP (`minis-mcp-cli`), `minis-scheduled`, and `/var/minis/shared` for files the agents share.

## 3. Data model (from the recon, trimmed to an MVP)

```swift
struct MuxGroup: Codable, Identifiable { id; name; members: [MuxMember]; layout: .list | .grid(cols) }
struct MuxMember: Codable { endpointId; role: String? }        // "lead", "builder" → role@group
struct AgentEndpoint: Codable, Identifiable {
    id; displayName; hostId: UUID?                           // nil = on this phone
    kind: .localSession(chatSessionId) | .tmuxPane(session, paneId) | .codexAppServer(url) | .companion(agentId)
    lastState: AgentState; lastSeen: Date
}
struct MuxHost: Codable, Identifiable { id; label; os; address /* MagicDNS or 100.x */; transport: .sshTmux | .companion }
enum AgentState: String, Codable { case working, blocked, done, idle, unknown, disconnected, suspended }
```

`suspended` is our own addition, because a phone app is suspended far more often than a desktop
terminal. `blocked` always carries a reason and a prompt id (from OpenRig): you can't answer a prompt you
can't name.

## 4. Networking

- **Tailscale** for reachability, which is already how the deploy pipeline reaches the desktop.
- **SSH** for the first transport. Citadel or SwiftNIO-SSH on iOS, with keys in the Keychain and the host key pinned.
- **Windows:** use OpenSSH Server. Tailscale SSH works only on Linux and macOS. For the backend, use tmux in WSL2, `psmux`, or Herdr's native Windows server.
- **The remote side holds the state; the phone reattaches.** iOS can't keep sockets open in the background, so on foreground the app reconnects with backoff, takes a snapshot, then subscribes from the last offset. While backgrounded, a small daemon on each host (phase 5) sends push notifications (ntfy or an APNs relay) when an agent goes `→blocked` or `→done`, with a `nabla://mux/...` deep link.

## 5. On-device and off-device agents in one group

- **A channel per group.** An append-only `channel.jsonl`. It lives in `/var/minis/shared/mux/<group>/`
  for on-device groups, and on the companion host for mixed groups (the host is always reachable; the
  phone isn't).
- **`mux-mcp` tools** (`mux_list_members`, `mux_read`, `mux_send`, `mux_post`, `mux_wait`, `mux_task_claim/close`)
  are served to remote CLIs over SSH stdio and registered for the in-app agent via `minis-mcp-cli`. Both
  sides then use the same verbs.
- **Messages from other agents are untrusted.** They are wrapped as `<mux-message from="builder@g1">…</mux-message>`.
  Approving a permission across agents is off by default, and agent-to-agent sends are rate-limited.
- **Conductor mode.** The in-app agent can act as the group lead. It reads the channel, assigns tasks, and
  is woken by push or by `minis-scheduled`.

## 6. Build plan

| phase | scope | done when |
|---|---|---|
| 0 spike | SSH over Tailscale from the app; `tmux list-panes`; render `capture-pane -e` in the existing emulator | a remote Claude Code pane is visible on the phone |
| 1 MVP | groups, endpoints, persistence; `/mux add` (current chat) and `/mux attach` (remote pane picker); grid with 1–2 s polling; type into a card via `send-keys -l`; tap to open the full session | the user can watch and steer one local and two remote agents in a group |
| 2 live | `tmux -CC` streaming for the focused card; off-screen panes off; reconnect on foreground | smooth live terminal; no desktop resize |
| 3 structured | Claude hooks that set `@agent_state`; a Codex app-server endpoint with approval cards | exact blocked/idle states; approve from the phone |
| 4 cooperate | group channel, `mux-mcp`, task queue, role addressing | the in-app agent assigns work to a remote Claude and gets the result back |
| 5 daemon | `muxd` with tsnet, ring buffers, push, Windows support | the phone can sleep for hours and catch up instantly |

## 7. Lessons from the harness review that apply here

- **Expose our own agent through a machine protocol.** Every major harness does this: JSON lines over stdio, ACP, or HTTP/WebSocket. If the Nabla agent spoke ACP or the Pi-style RPC event set, a desktop multiplexer could drive the phone's agent, not just the other way round. That symmetry is what makes "on and off device in one group" real rather than one-way.
- **Sessions as an append-only tree** (Pi). Each entry links to its parent, so branches live in one file, and compaction and summaries are entries too. This fits Mux's "go to session" and future branching.
- **Hook event names shared with Claude Code and Codex** (`PreToolUse`, `PostToolUse`, `Stop`, `Notification`). The `dsh` harness already runs hooks written for either. Adopting the same names means a hook written for a desktop agent can also drive our state reporting.
- **Approval modes as a named policy** (Codex): what is possible and when to ask are separate settings. Background and scheduled runs default to deny.

### Added from the final harness report
- **Build an ACP adapter first for structured remote agents.** One adapter covers Gemini CLI, Goose,
  Hermes, OpenCode and DeepSeek's `dsh`. Codex app-server and Claude Code (stream-json + hooks) need
  their own adapters.
- **One approvals inbox** across all members of all groups. Codex app-server, OpenCode and Hermes send
  approval requests over the wire; Claude Code exposes per-agent state via `claude agents --json`.
- **herdr's report contract** for plain terminal agents: report idle/working/blocked, a resume command,
  and release on exit.

## 8. Open questions for the user

1. Groups on the phone only, or mirrored to a host? Mirroring is needed for push while the phone sleeps.
2. Which remote agents first: Claude Code, Codex, or both? Codex's app-server gives the cleanest
   structured channel; Claude's hooks give the cleanest state.
3. Windows backend: tmux in WSL2 (most compatible), or native via psmux or Herdr?
4. Should the in-app agent be allowed to act as conductor (send to other agents) by default, or only
   when the user enables it per group?
