# Agent Harness Architecture Review — What an On-Device iOS Agent App Should Adopt

*Prepared for: team building an iOS agent app forked from OpenMinis (tool loop, iSH Linux shell, MCP, sub-agents, skills-as-markdown, SOUL.md persona, slash commands, memory files).*
*Research date: 2026-10-11/12 (America/Phoenix). Sources: upstream GitHub repos (via GitHub API + raw files) and official docs sites. Each claim cites a repo path or a docs URL.*

## How to read this

- **[verified]**: read in the primary source (README, docs page, or source tree listing) during this research.
- **[uncertain]**: inferred, version-dependent, or only seen in passing. Check it before you build on it.
- These projects change weekly. Several features below are labelled "experimental", "research preview" or "developer preview" by their own docs. Pin versions before you integrate.
- Star counts are GitHub API snapshots from 2026-10-12. They show relative popularity and nothing more.

---

## 0. TL;DR

1. **Every serious harness now separates the agent core from the UI with a machine protocol.** There are three families:
   - **JSONL over stdio:** Pi `--mode rpc`, Claude Code `-p --input-format/--output-format stream-json`, Codex app-server (JSON-RPC over stdio by default), DeepSeek Harness `dsh --profile sdk`, Hermes TUI-gateway JSON-RPC.
   - **ACP (Agent Client Protocol, JSON-RPC over stdio):** Hermes, Gemini CLI, Goose, OpenCode, DeepSeek Harness. Many also act as ACP *clients* that delegate to other agents.
   - **HTTP/WebSocket servers:** OpenCode `opencode serve` (OpenAPI + SSE), Codex app-server `--listen ws://|unix://`, Goose `goose serve`, Hermes OpenAI-compatible API server, DeepSeek Harness `dsh web`.

   Your iOS app should expose one of these. Recommendation: implement **ACP as the interop surface**, with a **Pi-style RPC/event vocabulary** (prompt / steer / follow_up / abort / fork / get_state / agent_settled) internally.
2. **Session = append-only JSONL event log; context = projection of that log.** Pi (id/parentId tree in one JSONL file), Codex (rollout JSONL + `thread/fork`), DeepSeek Harness ("model-visible means logged"; versioned JSONL) and Claude Code (`.jsonl` transcripts, `/branch`, `--fork-session`) all converge here. Adopt **Pi's session tree** (branches inside one file plus summary entries for abandoned branches). It is the cleanest model and maps well to a phone UI.
3. **Permissions split into two orthogonal axes:** *sandbox* (what is technically possible) and *approval policy* (when to ask). Codex's model is the cleanest: `read-only | workspace-write | danger-full-access` × `on-request | never | granular` plus an auto-reviewer. Claude Code adds named modes (`default`, `acceptEdits`, `plan`, `auto`, `dontAsk`, `bypassPermissions`). On iOS the OS sandbox is already there; you need the **approval-policy axis plus per-tool rules**, and you deliver approvals as **server→client requests** in your protocol.
4. **Hooks are now table stakes**, and the event names have converged:
   - `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `PreCompact`/`PostCompact`, `SubagentStart`/`SubagentStop`, `Stop` appear in Claude Code and Codex.
   - Gemini CLI uses `Before*`/`After*` names.
   - DeepSeek Harness ships *bridges* that run Claude-Code- and Codex-format `hooks.json` files.

   Copy the Claude/Codex event names and JSON stdin/stdout contract so users' existing hooks port over.
5. **Context files have standardised on `AGENTS.md`.**
   - Codex, Pi, Hermes, OpenCode and DeepSeek Harness read `AGENTS.md`.
   - Claude Code reads `CLAUDE.md` and now `AGENTS.md`.
   - Pi and Hermes also read `CLAUDE.md`.
   - `AGENTS.override.md` is used by Codex, Pi and Hermes.
   - Hermes uses `SOUL.md` as an identity slot separate from project context, which is the same as your design.

   Skills have standardised on `SKILL.md` + frontmatter with progressive disclosure (the agentskills.io standard is cited by Claude Code and Hermes).
6. **Sub-agents: three patterns.**
   - **(a) In-process child with a fresh context that returns only a summary** (Claude Code Agent tool, Hermes `delegate_task`, Codex `spawn_agent`/`wait`, OpenCode Task/@mention, Gemini CLI subagents).
   - **(b) Fork:** a child that inherits the full history (Claude Code fork/`/subtask`, DeepSeek fork-in-process).
   - **(c) Out-of-process agents driven over a protocol** (Pi's subagent extension spawns `pi` processes; DeepSeek Harness has subagent backends for ACP, Claude Code and Codex; Goose delegates to ACP agents).

   Pattern (c) is exactly what a multi-agent manager needs.
7. **Agent managers have appeared.**
   - Claude Code ships a supervisor daemon plus `claude agents --json` (states: `working`/`blocked`/`done`/`failed`/`stopped`).
   - Codex ships an app-server daemon.
   - Third-party multiplexers (herdr, cmux) define a simple **state-report contract**: `idle`/`working`/`blocked` + a resume command + a release. That three-state model plus "what is it blocked on" is the minimum your tmux-style manager should standardise.

**DeepSeek finding:** there **is** an official DeepSeek agent harness: **`deepseek-ai/deepseek-harness`** (`dsh`, TypeScript, "Everything is a Plugin", built on Cordis, MIT, developer preview, ~248k stars). A separate repo `deepseek-ai/awesome-deepseek-agent` is a list repo whose contents were not inspected. No official "deepseek-tui" exists. `Hmbown/deepseek-tui` now redirects to **`codewhale-hq/Codewhale`** (Rust, model-agnostic; it is not a DeepSeek product). Popular community DeepSeek-oriented agents include `esengine/DeepSeek-Reasonix` (Go) and `lessweb/deepcode-cli`. See §5.

---

## 1. Comparison matrix

| | Pi | Hermes Agent | Claude Code | Codex CLI | DeepSeek Harness | OpenCode | Goose | Gemini CLI |
|---|---|---|---|---|---|---|---|---|
| Repo | earendil-works/pi (was badlogic/pi-mono) | NousResearch/hermes-agent | anthropics/claude-code (closed core; repo = docs/examples/mods) | openai/codex (Rust `codex-rs`) | deepseek-ai/deepseek-harness | anomalyco/opencode (was sst/opencode) | aaif-goose/goose (was block/goose) | google-gemini/gemini-cli |
| Lang | TypeScript (Node ≥22.19) | Python (+ Ink TUI, Electron desktop) | TypeScript/Bun binary (closed source) | Rust | TypeScript (Cordis plugins) | TypeScript | Rust (+ Electron desktop) | TypeScript |
| Process model | single process; SDK in-proc; RPC child process; experimental server/durable runtime | AIAgent core behind CLI, gateway, ACP, API server, TUI-gateway | CLI process; background sessions under a supervisor daemon | core engine with SQ/EQ queues; TUI ↔ app-server (JSON-RPC); optional daemon | plugin tree booted from a profile (web / headless / sdk / acp) | TUI is a client of a local HTTP server | interface → agent → MCP extensions; `goose serve` | CLI; ACP mode |
| Machine protocol | `--mode json` (JSONL events), `--mode rpc` (JSONL cmds+events), TS SDK | ACP stdio; TUI-gateway JSON-RPC (stdio/WS); OpenAI-compatible HTTP API; Python import | `-p` + `--output-format json/stream-json`, `--input-format stream-json`; Agent SDK (TS/Py); `claude agents --json` | `codex exec --json`; app-server JSON-RPC (stdio / ws / unix) + generated TS/JSON schemas; TS & Py SDK | `dsh headless --json`; `dsh sdk` (JSON-RPC over NDJSON stdio); ACP; web `/api` | OpenAPI 3.1 HTTP + SSE `/event`; JS SDK; ACP | ACP (`goose acp`, `goose serve`); `goose run` headless | `-p --output-format json/stream-json`; `--acp` |
| Default tools | read, bash, edit, write (+grep/find/ls optional; codemode, tool_search) | 70+ tools / 28 toolsets | ~45 incl. Agent, Bash, Edit, Read, Write, Web*, Task*, Cron*, Monitor, SendMessage, Workflow, Skill, LSP | shell/unified_exec, apply_patch, plan, view_image, request_user_input, multi-agent, MCP, tool_search | plugin-provided: bash, fs, str-replace editor, web, todo, skill, subagent, jobs, schedule, LSP… | bash, edit, write, read, grep, glob, apply_patch, skill, webfetch, websearch, question, lsp | MCP extensions (developer, etc.) | file, shell, web, memory, etc. |
| Sub-agents | none in core; example extension spawns `pi` processes; durable runtime has owned child conversations | `delegate_task` (≤10 concurrent by default; depth 1 by default); Kanban multi-process workers | Agent tool (Explore/Plan/general), custom `.claude/agents/*.md`, forks, agent teams, workflows, cross-session messaging | spawn_agent / send_input / wait / close_agent (+v2: list/message/interrupt); custom `.codex/agents/*.toml` | subagent seam with backends: in-process spawn/fork, ACP, Claude Code, Codex, DSH SDK; agent teams (experimental) | primary agents (Build/Plan) + subagents (General/Explore/Scout) via @mention / task | subagents, subrecipes (parallel) | subagents exposed as tools |
| Session persistence | JSONL **tree** (id/parentId), `/tree` `/fork` `/clone`, branch summaries | SQLite + FTS5, lineage via parent_session_id | `.jsonl` transcripts; `--resume`/`--continue`; `/branch`; `--fork-session`; checkpoint rewind | rollout JSONL; `thread/resume`, `thread/fork`, rollback | append-only versioned JSONL(.zstd) event log; fork/resume derive from it | server sessions; fork at message; revert/unrevert | sessions, resume | session management, checkpoint (shadow git) |
| Context mgmt | auto-compaction (summary entry; originals kept); branch summaries; context_edit entries | 50% compressor + 85% gateway hygiene; pluggable ContextEngine; MEMORY.md / USER.md | auto-compact, `/compact`, CLAUDE.md + auto memory, tool search | compaction prompt, memories pipeline (2-phase), AGENTS.md chain (32 KiB cap) | pluggable compaction seam (basic, tool-result pruner, image offload) | `/session/:id/summarize`, compaction plugin hook | auto-compaction + fallback strategies | PreCompress hook; GEMINI.md; auto-memory |
| Extension points | TS extensions (events, tools, commands, UI), skills, prompt templates, packages (npm/git), MCP | plugins (memory, context engine, providers, platforms), hooks (gateway + plugin), skills (self-authored), MCP | settings hooks (command/http/mcp_tool/prompt/agent), skills, plugins + marketplaces, mods (in-process JS), MCP, channels, output styles | hooks, skills, plugins, MCP client, execpolicy rules, custom agents | everything is a Cordis plugin; profiles/bundles/patches; Claude Code hook & mods bridges | JS/TS plugins (event bus), custom tools, agents, commands, MCP | MCP extensions, recipes | extensions, hooks, skills, policy engine |
| Permission / sandbox | **none built in** (by design); container/VM recommended; project trust | approval modes smart/manual/off; hardline blocklist; write-safe root; 7 terminal backends (Docker/SSH/Modal…) | 6 permission modes + allow/ask/deny rules; OS sandbox for Bash (Seatbelt / bubblewrap) | sandbox modes × approval policy; Seatbelt / Landlock+bwrap / Windows; execpolicy (Starlark); auto-review | sandbox seam (bwrap/Landlock, Seatbelt, Windows ACL, SSH); approval seam (fail-closed) | allow/ask/deny per tool/pattern | Autonomous / Manual / Smart / Chat-only | Seatbelt profiles or Docker/Podman/gVisor; trusted folders; policy engine |

---

## 2. Pi (Mario Zechner / earendil-works)

**Identity [verified].** `github.com/badlogic/pi-mono` now redirects (GitHub API 301) to **`github.com/earendil-works/pi`**, "AI agent toolkit: unified LLM API, agent loop, TUI, coding agent CLI" (TypeScript, MIT, ~114k stars). npm scope is now `@earendil-works/*`, e.g. `@earendil-works/pi-coding-agent`. Site: https://pi.dev. Sessions of Pi's own development are published on HF (`badlogicgames/pi-mono`) per `packages/coding-agent/README.md`.

**Packages** (root `README.md`) [verified]:
- `pi-ai`: unified multi-provider LLM API.
- `pi-agent-core`: agent runtime with tool calling and state.
- `pi-coding-agent`: the CLI.
- `pi-tui`: terminal UI with differential rendering.
- Newer packages: `pi-durable` (durable conversation/task runtime, experimental), `chord` (service/replicated-state/RPC composition runtime), `pi-protocol`, `pi-server`, `pi-client` (experimental routed server/protocol), `pi-telemetry`.
- Slack/chat automation lives in a separate repo, `earendil-works/pi-chat`.
- OpenClaw is cited as a real-world SDK integration.

### Philosophy
- "Pi is a minimal, extensible agent harness that you can make your own… Pi ships with powerful defaults but **skips features like sub-agents and plan mode**. Ask Pi to build what you want, or install a package that does it your way." (root `README.md`) [verified]
- **Minimal default toolset.** Enabled by default: `read`, `bash`, `edit`, `write`. Also available: `grep`, `find`, `ls`, `powershell`. Two opt-in built-in extensions:
  - `codemode`: JS run in a QuickJS sandbox that calls other tools, e.g. in parallel via `Promise.allSettled`; only the script output reaches the model.
  - `tool_search`: declares deferred tools on demand.

  Source: `packages/coding-agent/docs/cli.md` §Tools [verified].
- **No permission system, deliberately.** "Pi does not include a built-in permission system… runs with the permissions of the user." Recommended alternatives: containerization (Gondolin micro-VM extension, Docker, OpenShell). There is also a "project trust" gate before loading project-level settings and resources (`README.md`, `docs/security.md`) [verified].

### Architecture and agent loop
- `docs/how-pi-works.md` [verified]: a submitted message is added to the active branch → request built from system prompt + active branch + tools → provider streams → tool calls executed → turn ends; repeats while tool results or queued messages exist.
- **Steering messages** are delivered after the current assistant turn. **Follow-up messages** are delivered after all pending work. Abort returns queued messages to the editor.
- All interfaces (interactive, print, JSON, RPC, SDK) share "the same agent and session mechanisms".

### Sessions: tree and branching (best-in-class)
- Persistent sessions are **JSONL files** under `~/.pi/agent/sessions/` grouped by cwd. Entries have `id`/`parentId`, forming a **tree in a single file**. The current leaf defines the active branch (`docs/session-format.md`, `docs/sessions.md`) [verified].
- Entry types:
  - `message`. System messages carry prompt *sections* and `toolsAdded`/`toolsRemoved` deltas, so the prompt and tool loadout can be replayed.
  - `model_change`, `thinking_level_change`, `usage`.
  - `compaction` (summary + `firstKeptEntryId` + system checkpoint).
  - `context_edit` (branch-relative omission/replacement of an entry's model-visible content).
  - `branch_summary`, `custom`, `custom_message`, `label`, `session_info`.
- Commands:
  - `/tree` moves within the file. Selecting a user message puts it back in the editor for edit-and-resubmit.
  - `/fork` creates a new session file from an earlier user message.
  - `/clone` copies the active branch to a new file.
- When leaving a branch, Pi can generate an LLM **branch summary** of the abandoned path and attach it to the branch you enter.
- `--continue`, `--resume`, `--session <path>`, `--no-session`, `--session-dir` [verified].

### Context management
- Auto-compaction near the context limit inserts a summary entry. **Original entries remain in the tree.** `/compact [instructions]` runs it manually (`docs/compaction.md`, `docs/sessions.md`) [verified].
- Context files (`docs/configuration.md`) [verified]:
  - `AGENTS.md` / `CLAUDE.md` (plus `AGENTS.override.md`) in the agent dir and project dirs.
  - `SYSTEM.md` replaces the system prompt; `APPEND_SYSTEM.md` appends to it, at both user and `.pi/` project level.
  - `--no-context-files`-style flag to disable AGENTS/CLAUDE discovery (`docs/cli.md`).
- Skills are loaded on demand: descriptions sit in the prompt, full content is read when needed (`docs/skills.md`).

### Extension points
- **Extensions** (`docs/extensions.md`) [verified]: TypeScript modules loaded in-process via `jiti`, with no build step. `export default function (pi: ExtensionAPI)` registers:
  - tools (TypeBox schema), commands, shortcuts, providers, renderers, TUI components;
  - event handlers.
- Events cover resources, session, agent/message lifecycle, providers and tools:
  - `tool_call` can mutate input or **block**; `tool_result` handlers compose; `message_end` can replace a message.
  - `before_agent_start` can change prompt sections or tools.
  - `context` / `context_with_system` transform the transcript.
  - `turn_end` / `agent_before_settle` can append entries and request continuation.
  - `user_bash` can intercept `!` commands; `project_trust` decides trust.
- Tool calls from one assistant message may run **in parallel**.
- **Pi packages** bundle extensions, skills, prompt templates and themes, distributed via npm or git (`docs/packages.md`).
- **MCP** is built in: stdio + streamable HTTP, `pi mcp add/list`, `~/.pi/agent/mcp.json` and `.pi/mcp.json`, with per-server "exposure" (direct / deferred / codemode-only) (`docs/mcp.md`) [verified].
- Prompt templates double as slash commands (`docs/prompt-templates.md`).

### Sub-agents
- Not in core. The official example `examples/extensions/subagent/` [verified]:
  - Each subagent is a **separate `pi` process** with an isolated context; output streams in parallel; Ctrl+C propagates.
  - Agent definitions are markdown (`~/.pi/agent/agents/*.md`, e.g. scout, planner, reviewer, worker); workflow prompts chain them (scout → planner → worker).
  - Project-local agents are opt-in for security.
- `pi-durable` (experimental) adds **task-owned child conversations**: abort propagates to children, background-owned tasks survive parent abort, and there are replay-safe subagent tools and a task graph (`packages/durable/README.md` §Abort and Subagents) [verified].

### Headless / programmatic
- `pi -p "…"` (print mode: final text).
- `pi --mode json "…"` emits JSONL events: session header, then `agent_start`, `turn_start`, `message_start`/`message_update` (text deltas)/`message_end`, tool events, `turn_end`, `agent_end`, **`agent_settled`**. Source: `docs/json.md` [verified].
- **RPC mode** `pi --mode rpc` (`docs/rpc.md`, `docs/rpc-commands.md`) [verified]:
  - A long-lived child process with JSONL commands on stdin and responses + events on stdout.
  - Commands: `prompt`, `steer`, `follow_up`, `abort`, `clear_queue`, `new_session`, `get_state`, `get_messages`, `set_model`, `cycle_model`, `set_thinking_level`, `compact`, `set_auto_compaction`, `set_auto_retry`, `bash`, `abort_bash`, `get_session_stats`, `export_html`, `switch_session`, `fork`, `clone`, `get_tree`, `get_entries`, `get_last_assistant_text`, `set_session_name`, `get_commands`.
  - Optional `id` correlation; `prompt` returns a `disposition` (`started` / `handled` / …).
  - The "extension UI" record family forwards extension dialogs to the client.
  - Framing rule: split strictly on LF, never on U+2028/2029 (warns against Node `readline`).
  - Typed `RpcClient` in TypeScript.
- **SDK**: in-process TS (`docs/sdk.md`) with a `SessionManager` API.
- **tmux**: `docs/tmux.md` covers extended-key config only. There is no manager integration.

**Takeaways for iOS:** the session-tree format; the RPC command vocabulary (especially `steer` vs `follow_up` and `agent_settled`); system-prompt-as-replayable-deltas; `context_edit`; tool-exposure tiers (direct / deferred / codemode).

---

## 3. Hermes Agent (Nous Research)

**Identity [verified].** `github.com/NousResearch/hermes-agent`, "The agent that grows with you" (Python, ~253k stars). Docs: https://hermes-agent.nousresearch.com/docs. The repo has its own `SOUL.md`, `AGENTS.md`, `apps/desktop` (Electron) and Termux packaging.

### Architecture
Source: `website/docs/developer-guide/architecture.md` [verified].
- One `AIAgent` core (`run_agent.py`; loop in `agent/conversation_loop.py`) behind many entry points:
  - CLI (`cli.py`), **messaging gateway** (`gateway/run.py`), **ACP server** (`acp_adapter/`);
  - batch runner, OpenAI-compatible **API server**, Python library;
  - Ink TUI over a **TUI-gateway JSON-RPC**.
- Three API modes: chat_completions, codex_responses, anthropic.
- Tool registry: "70+ tools, 28 toolsets" (`tools/registry.py`, `toolsets.py`).
- Session storage: **SQLite + FTS5** (`hermes_state.py`).
- **Seven terminal backends**: local, Docker, SSH, Singularity, Modal, Daytona, Vercel Sandbox (README).
- **Gateway** [verified]: one process serving Telegram, Discord, Slack, WhatsApp, Signal, Matrix, email, SMS, Feishu, WeCom, Teams and more as plugins (`plugins/platforms/`). Includes DM pairing authorization, cross-platform continuity and voice memo transcription.

### Self-improvement loop (the distinctive feature)
- **Skills** (`features/skills.md`) [verified]:
  - `~/.hermes/skills/` is the source of truth; the format is SKILL.md (agentskills.io compatible).
  - Progressive disclosure: `skills_list` (~3k tokens) → `skill_view(name)` → `skill_view(name, path)`.
  - The agent **creates and patches skills itself** via `skill_manage` after complex tasks, with an optional write-approval gate.
  - `/learn` turns docs, URLs or the current conversation into a skill.
  - Precedence: project → local → `create_dir` → external dirs.
- **Curator** (`features/curator.md`) [verified]: periodic idle-time review (default every 7 days, after ≥2 h idle) of *agent-created* skills. It consolidates and archives (never deletes), keeps an audit ledger and rollback, and supports pinning.
- **Memory** (`features/memory.md`) [verified]:
  - Two bounded files: `MEMORY.md` (2,200 chars) and `USER.md` (1,375 chars) in `~/.hermes/memories/`.
  - Injected as a **frozen snapshot at session start**, with a usage-percentage header.
  - Managed by a `memory` tool (add / replace / remove). No auto-compaction: a write over the limit errors and the agent must consolidate.
  - "One agent per Hermes home" warning.
  - Plus `session_search` (FTS5 over past sessions with LLM summarization) and pluggable memory providers (e.g. Honcho).
- **Context files** (`features/context-files.md`) [verified]:
  - `.hermes.md` → `AGENTS.override.md` → `AGENTS.md` (git-root→cwd chain merged) → `CLAUDE.md` → `.cursorrules`; first match wins per type.
  - **`SOUL.md` always loaded separately as identity (slot #1)**. This is the same concept as OpenMinis' SOUL.md.

### Sub-agents and orchestration
- **`delegate_task`** (`features/delegation.md`) [verified]:
  - Children are isolated `AIAgent` instances with fresh context; only the summary returns.
  - Single task or a batch of up to 10 concurrent by default.
  - Optional `output_schema` with one correction turn on validation failure.
  - Depth defaults to flat (`max_spawn_depth: 1`); `role="orchestrator"` allows nesting when raised.
  - Top-level delegations run **in the background** and post results back as new messages.
  - Children own their background processes.
  - Project context files are inherited; SOUL.md is not.
- **Kanban** (`features/kanban.md`) [verified]: durable SQLite task board (`~/.hermes/kanban.db`) shared across profiles. "Every worker is a full OS process with its own identity." This is a multi-process alternative to in-process swarms.
- Mixture-of-agents, `/review`, `execute_code` (Python scripts that call tools via RPC, "zero-context-cost turns").

### Scheduling
- Built-in **cron** (`features/cron.md`) [verified]:
  - Jobs run in fresh sessions with attached skills and deliver to any platform.
  - No-agent script mode.
  - Webhook-triggered jobs.
  - The agent manages jobs via a `cronjob_manage` tool.

### Hooks and plugins
- **Gateway event hooks**: `~/.hermes/hooks/<name>/HOOK.yaml` + `handler.py`.
- **Plugin hooks**: `pre_tool_call`, `post_tool_call`, `pre_llm_call`, `post_llm_call`, `on_session_start`, streaming hooks, and more (`features/hooks.md`) [verified].
- Plugin types: memory provider, context engine, model/image/video/web-search providers, platforms, secret sources (`developer-guide/*-plugin.md`).

### Permissions
Source: `user-guide/security.md` [verified].
- `approvals.mode: smart | manual | off`.
- Separate behaviour for cron, single-query and unattended sessions (`deny` / `approve`).
- Hardline blocklist; user deny rules; permanent allowlist; `hermes approvals suggest` mines approval history.
- Protected write paths and `HERMES_WRITE_SAFE_ROOT`; container isolation.
- Checkpoints: a shadow git repo snapshots before file writes and destructive commands (`checkpoints-and-rollback.md`).

### Programmatic surfaces
Source: `developer-guide/programmatic-integration.md` [verified].
1. **ACP** (`hermes acp`, stdio JSON-RPC): sessions, prompt, streaming chunks, tool-call events, permission requests, session fork, cancel.
2. **TUI-gateway JSON-RPC** (stdio or WebSocket):
   - Methods: `prompt.submit`, `prompt.background`, `session.steer`, `session.create/list/active_list/activate/close/interrupt/history/compress/branch/status`, `delegation.status`, `subagent.interrupt/steer`, `spawn_tree.save/list/load`, `command.dispatch`, …
   - Events: `message.delta/complete`, `tool.start/generating/complete`, …
   - **Approvals, clarify, sudo and secret prompts are server→client JSON-RPC requests**.
   - Multiple clients can attach to one live session.
   - Reconnect replays `inflight` turn state and `open_requests`.
   - A documented **Pi-RPC → Hermes mapping table** exists.
3. **OpenAI-compatible HTTP API server**.

Hermes explicitly has no `--mode rpc` flag.

**Takeaways for iOS:**
- Self-authored skills plus a curator.
- Bounded memory files with capacity headers.
- SOUL.md as a separate identity slot (you already have this).
- Background delegation that posts results back as messages.
- Server→client approval requests with reconnect replay of open requests. This is ideal for a phone that disconnects often.
- The multi-platform gateway is mostly irrelevant on-device. iOS can instead *be* a client of a remote Hermes gateway.

---

## 4. Claude Code (Anthropic)

**Identity [verified].** `github.com/anthropics/claude-code` (~150k stars). The repo contains README, examples, `.devcontainer`, and many `mods/` examples, **not the agent source**. The product is distributed as a closed binary. Docs: https://code.claude.com/docs (index at `/docs/llms.txt`; every page has a `.md` twin). Agent SDK repos: `anthropics/claude-agent-sdk-typescript`, `anthropics/claude-agent-sdk-python`.

### Tools
Source: `/docs/en/tools-reference.md` [verified]. About 45 tools:
- Core: `Agent` (subagents), `Bash`, `PowerShell`, `Read`, `Edit`, `Write`, `NotebookEdit`, `Glob`/`Grep`.
  - Glob/Grep are *absent by default on macOS, Linux and WSL*: Claude uses `find`/`grep` via Bash with embedded `bfs`/`ugrep`. This is a minimal-tool move similar to Pi.
- Web and code intelligence: `WebFetch`, `WebSearch`, `LSP`.
- Background and scheduling: `Monitor` (background command whose lines stream back), `CronCreate/List/Delete`, `ScheduleWakeup`, `RemoteTrigger` (cloud Routines).
- Tasks: `TaskCreate/Get/List/Update/Stop/Output` (replacing `TodoWrite`).
- Multi-agent: `SendMessage` / `ListAgents` (cross-agent messaging), `Workflow` (dynamic workflows), `SubagentHandback`.
- Modes and worktrees: `EnterPlanMode`/`ExitPlanMode`, `EnterWorktree`/`ExitWorktree`.
- User interaction: `AskUserQuestion`, `PushNotification`, `SendUserFile`.
- Extensibility: `Skill`, `ToolSearch`, MCP resource tools, `Artifact`.

### Sub-agents and multi-agent
- **Subagents** (`/docs/en/sub-agents.md`) [verified]:
  - Built-ins: Explore (read-only), Plan, general-purpose.
  - Custom agents are markdown + YAML frontmatter in `.claude/agents/` (project), `~/.claude/agents/` (user), or `--agents` JSON.
  - Frontmatter fields: `name`, `description`, `tools`, `disallowedTools`, `model`, `permissionMode`, `maxTurns`, `skills`, `mcpServers`, `hooks`, `memory`, `background`, `omitClaudeMd`, `effort`, `isolation: worktree`, `color`, `initialPrompt`.
  - Foreground or background execution.
  - Nested spawning up to 3 layers by default (`CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH`).
  - **Forks** (`/subtask`): a child that inherits the full conversation and runs in the background.
- **Agent teams** (`/docs/en/agent-teams.md`, experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`): a lead session plus teammate sessions with their own contexts that message each other directly.
- **Dynamic workflows** (`/docs/en/workflows.md`): Claude writes a JavaScript script that orchestrates many subagents, executed by a background runtime.
- **Cross-session messaging** (`/docs/en/cross-session-messaging.md`): one local session can send text to another.
- **Agent view + supervisor** (`/docs/en/agent-view.md`, research preview) [verified]:
  - `claude agents` is a full-screen table of background sessions: Working / Needs input / Done / Failed / Stopped.
  - Peek / reply / attach / detach.
  - A **supervisor daemon** hosts each background session as its own process, restarts crashed ones, reaps idle ones after about an hour, and survives updates.
  - Shell control: `claude --bg`, `claude attach|logs|stop|respawn|rm <id>`, `claude daemon status|logs|stop`.
  - **`claude agents --json [--all]`** is the "supported way to read session state from outside Claude Code". Fields: `id`, `state` (`working|blocked|done|failed|stopped`), `status` (`busy|waiting|idle`), `waitingFor` (`permission prompt`, `input needed`, `sandbox request`, …), `sessionId`, `cwd`, `pid`.
  - `~/.claude/jobs/<id>/` files are explicitly *not* a stable interface.
- **Remote Control** (`/docs/en/remote-control.md`): drive a local session from claude.ai or the iOS/Android Claude app. Execution stays local; multiple surfaces stay in sync.
- **Channels** (research preview): MCP servers that *push* events (Telegram, Discord, iMessage) into a running session.

### Hooks
Source: `/docs/en/hooks.md` [verified].
- Handler types: `command`, `http`, `mcp_tool`, `prompt`, `agent`.
- Common fields: `if` (permission-rule filter such as `Bash(git *)`), `timeout`, `async`, `once`.
- Events seen in the reference: `SessionStart`, `Setup`, `UserPromptSubmit`, `UserPromptExpansion`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `PermissionRequest`, `PermissionDenied`, `Notification`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop`, `SubagentHandback`, `PreCompact`, `PostCompact`, `TaskCreated`, `TaskCompleted`, `TeammateIdle`, `Elicitation`, `ElicitationResult`, `WorktreeCreate/Remove`, `FileChanged`, `CwdChanged`, `ConfigChange`, `InstructionsLoaded`, `Pre/PostModelSwitch`, `MessageDisplay`, `SessionEnd`, `EndConversation`, `DirectoryAdded`.
- Exit code 2 = block.

### Skills, commands, plugins, mods
- **Skills** (`/docs/en/skills.md`) [verified]:
  - `SKILL.md` follows the agentskills.io open standard.
  - "Custom commands have been merged into skills": `.claude/commands/x.md` and `.claude/skills/x/SKILL.md` both create `/x`.
  - Frontmatter includes `allowed-tools`, `disable-model-invocation`, `context: fork` (run in a forked subagent), `paths`.
  - Only descriptions sit in context until invoked.
- **Plugins** (`/docs/en/plugins/overview.md`): bundles of skills, agents, hooks, MCP servers, LSP and more; installed from marketplaces.
- **Mods**: plugins with an in-process JS/TS "hooks module" that can draw panes, restyle the UI, intercept tool calls or requests (`/docs/en/plugins/mods/overview.md`) [verified]. This is the in-process analogue of Pi extensions.

### Memory and context
- `CLAUDE.md` hierarchy (managed, user, project, local), `@imports`, `.claude/rules/`, **AGENTS.md support**, plus **auto memory** (`/docs/en/memory.md`) [verified].
- Auto-compaction and `/compact`. After compaction the system prompt, CLAUDE.md, memory and MCP tools reload, and up to 5 recent files are re-read (`/docs/en/context-window.md`).
- MCP tool search defers tool schemas.

### Permissions and sandbox
- **Modes** (`/docs/en/permission-modes.md`) [verified]:
  - `default` (Manual): reads only run without asking.
  - `acceptEdits`.
  - `plan`.
  - `auto`: server-side classifier reviews actions.
  - `dontAsk`: deny anything not pre-approved, for CI.
  - `bypassPermissions`.
- Allow / ask / deny rules (`Bash(npm *)`, `Edit(src/**)`). Deny always wins. Protected and critical paths.
- **Sandbox** (`/docs/en/sandboxing.md`): OS-enforced for Bash/PowerShell/Monitor only (Seatbelt on macOS, bubblewrap + socat on Linux/WSL2), with filesystem and network-domain allowlists. File tools, MCP and hooks run outside it.

### Sessions
- Local `.jsonl` transcripts; `--continue`, `--resume <id|path>`, `/resume` picker; `/branch` and `--fork-session` create new session IDs (`/docs/en/sessions.md`) [verified].
- Checkpointing/rewind of file edits (`/docs/en/checkpointing.md`).

### Headless and SDK
- `claude -p` with `--output-format text|json|stream-json` (+ `--verbose --include-partial-messages` for token deltas), `--json-schema` structured output, `--input-format stream-json` (multi-turn over stdin), `--resume <session_id>`, `--max-turns`, `--allowedTools`, `--permission-mode`.
- `--permission-prompt-tool <mcp tool>` delegates approvals to an MCP tool. `--permission-prompts none` exists.
- `--bare` skips auto-discovery and is recommended for scripts (`/docs/en/headless.md`, `/docs/en/cli-reference.md`) [verified].
- **Claude Agent SDK** (TS/Python) "runs the Claude Code binary" as a library. It offers streaming-input mode, sessions, hooks, permissions/`canUseTool`, subagents, skills, plugins and hosting guidance (`/docs/en/agent-sdk/overview.md`) [verified]. [uncertain] The SDK ↔ CLI wire format (stream-json with control messages) is not publicly specified as a stable protocol; treat the SDK as the contract.

**Takeaways for iOS:**
- Hook event taxonomy and JSON contract.
- Subagent-as-markdown-file frontmatter.
- Skills = commands unification.
- Permission mode names.
- `agents --json` state vocabulary (working / blocked / done + `waitingFor`).
- Remote Control proves the "phone drives a desktop agent" use case.
- Channels: push-events-into-session via MCP.

---

## 5. OpenAI Codex CLI

**Identity [verified].** `github.com/openai/codex` (Rust workspace `codex-rs/` with ~130 crates; npm `@openai/codex`; ~129k stars). Docs: https://learn.chatgpt.com/docs (index `https://developers.openai.com/codex/llms.txt`, which points to learn.chatgpt.com `.md` pages).

### Architecture and protocol
- `codex-rs/docs/protocol_v1.md` [verified]: the `Codex` core engine "runs locally, either in a background thread or separate process" and talks to any UI via a **Submission Queue / Event Queue** pair.
  - Entities: Session (configured via `Op::ConfigureSession`), Task (one at a time per session), Turn.
  - "for parallel tasks it is recommended that a single `Codex` be run for each thread of work."
  - Crates `codex-rs/protocol`, `core`, `tui`, `exec`, `app-server`, `app-server-protocol`, `app-server-client`, `app-server-daemon`, `thread-store`, `rollout`, `hooks`, `skills`, `execpolicy`, `linux-sandbox`, `windows-sandbox-rs`, `network-proxy`, `rmcp-client`, `agent-roles`, `agent-graph-store`, `memories`, … (tree listing).
- **App-server** (`https://learn.chatgpt.com/docs/app-server.md`, `codex-rs/app-server/README.md`) [verified]:
  - "the interface Codex uses to power rich clients (for example, the Codex VS Code extension)".
  - **JSON-RPC 2.0** with the `jsonrpc` header omitted.
  - Transports: `stdio` (JSONL, default); `ws://IP:PORT` (experimental; `/readyz`, `/healthz`; capability-token or signed-bearer auth); `unix://` socket.
  - Primitives: **Thread → Turn → Item**.
  - Methods: `initialize`, `thread/start|resume|fork|read|list|archive|delete|rollback|compact`, `turn/start|steer|interrupt`, `model/list`, review, command exec, filesystem.
  - Notifications: `turn/started`, `item/started|completed`, `item/agentMessage/delta`, …
  - **Approvals are server-initiated JSON-RPC requests**: `item/commandExecution/requestApproval` with decisions `accept`, `acceptForSession`, `decline`, `cancel`, `acceptWithExecpolicyAmendment`; plus `item/fileChange/requestApproval`, `tool/requestUserInput`, MCP elicitation.
  - `codex app-server generate-ts` / `generate-json-schema` emit **version-exact schemas**.
- **Remote TUI**: `codex app-server --listen ws://127.0.0.1:4500` and `codex --remote ws://…` (TUI on another machine).
- **App-server daemon**: `codex app-server daemon start|stop|enable-remote-control|bootstrap --remote-control` "used by remote clients such as the desktop and **mobile apps**"; every command writes one JSON object to stdout (`codex-rs/app-server-daemon/README.md`) [verified].
- **`codex mcp-server` has been removed.** Integrations must use app-server (`/docs/mcp-server.md`) [verified]. Codex remains an MCP *client*.

### Tools
Handlers in `codex-rs/core/src/tools/handlers/` [verified]:
- Execution and editing: `apply_patch`, `unified_exec` (`exec_command` + `write_stdin`: interactive PTY sessions), `view_image`.
- Planning and user interaction: `plan`, `request_user_input`, `request_permissions`.
- Multi-agent: `multi_agents` (spawn, send_input, wait, resume_agent, close_agent); `multi_agents_v2` (spawn, send_message, followup_task, interrupt_agent, list_agents, wait).
- Discovery and MCP: `tool_search`, MCP + MCP resources, `list_available_plugins_to_install`.
- Context and misc: `get_context_remaining`, `new_context_window`, `sleep`, `current_time`.
- Extensions: `ext/` (goal, memories, web-search, image-generation, agent-message-board).
- Philosophy: one powerful shell tool plus a patch tool, with model-specific prompts (`core/gpt_5_codex_prompt.md`, …).

### Sandbox and approvals (strongest model)
- Sandbox modes `read-only | workspace-write | danger-full-access`.
- Enforcement (`codex-rs/core/README.md`) [verified]:
  - macOS: Seatbelt via `/usr/bin/sandbox-exec` (`.git` and `.codex` are kept read-only even under workspace-write).
  - Linux: Landlock, with bubblewrap for split policies (bundled `bwrap` fallback).
  - Windows: restricted-token / elevated sandbox.
  - Network is off by default in workspace-write.
- Approval policy (`/docs/agent-approvals-security.md`): `on-request`, `never`, `granular {…}`. `untrusted` has been **retired**. `approvals_reviewer = "auto_review"` routes eligible prompts to a guardian model.
- **execpolicy**: Starlark `prefix_rule(pattern, decision=allow|prompt|forbidden, justification, match/not_match tests)` (`codex-rs/execpolicy/README.md`) [verified].

### Sub-agents
Source: `/docs/agent-configuration/subagents.md` [verified].
- Enabled by default; the model spawns agents when asked or when AGENTS.md or a skill says so; `/agent` switches between threads.
- Custom agents are TOML files in `~/.codex/agents/` or `.codex/agents/` (`name`, `description`, `developer_instructions`, plus any config key such as `model`, `sandbox_mode`, `mcp_servers`).
- `agents.max_concurrent_threads_per_session`.
- Template `core/templates/agents/orchestrator.md`.
- `ext/agent-message-board` gives agents shared channels backed by SQLite.

### Context and memory
- **AGENTS.md** chain: `~/.codex/AGENTS.override.md` or `AGENTS.md`, then project root → cwd, concatenated, 32 KiB cap (`project_doc_max_bytes`) (`/docs/agent-configuration/agents-md.md`) [verified].
- Compaction template `codex-rs/prompts/templates/compact/`.
- **Memories** pipeline (`codex-rs/memories/README.md`) [verified]: an async two-phase background job at root-session start (Phase 1 per-thread rollout extraction, Phase 2 consolidation). Skipped for ephemeral and sub-agent sessions.

### Hooks, skills, plugins
- Hooks (`/docs/hooks.md`) [verified]: `SessionStart`, `SessionEnd`, `SubagentStart`, `SubagentStop`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `UserPromptSubmit`, `Stop`, `Interrupt`. Background hooks, MCP-tool hooks, managed hooks via `requirements.toml`, a trust review step.
- Skills (`SKILL.md`, samples in `codex-rs/skills/src/assets/samples/`) and plugins (`/docs/skills-and-plugins.md`).

### Persistence and headless
- Threads are persisted as **rollout JSONL** (`codex-rs/thread-store/README.md`: `LocalThreadStore` → `codex-rollout` JSONL) plus a SQLite state DB.
- `codex exec "…"`: progress to stderr, final message to stdout.
- `--json` emits JSONL `thread.started`, `turn.started/completed`, `item.started/completed` (types such as `command_execution`, `agent_message`).
- `--output-schema`, `--ephemeral`, `codex exec resume --last` (`/docs/non-interactive-mode.md`) [verified].
- **Codex SDK**: TS `@openai/codex-sdk` (`startThread`/`run`/`resumeThread`); Python SDK drives app-server over JSON-RPC (`/docs/codex-sdk.md`) [verified].

**Takeaways for iOS:**
- The Thread/Turn/Item protocol with server→client approval requests and generated schemas is the most mature "agent-as-a-service" API. Mirror its shape.
- Sandbox × approval as two axes.
- execpolicy-style prefix rules with justification and inline tests.
- Codex explicitly targets **mobile apps as remote clients** via the daemon. Your iOS app can be a Codex app-server client to manage remote Codex agents.

---

## 6. "DeepSeek harness": what actually exists

### 6a. Official: DeepSeek Harness (`dsh`) [verified]
- **Repo:** `github.com/deepseek-ai/deepseek-harness`, "DeepSeek Harness: Everything is a Plugin." (TypeScript, MIT, default branch `master`, ~248k stars, last push 2026-10-09).
- **Docs:** https://deepseek-harness.github.io/deepseek-harness/
- **Run:** `npx @deepseek-ai/dsh web` (Web UI at 127.0.0.1:3080).
- **Status:** "developer preview… THERE WILL BE COMPATIBILITY-BREAKING CHANGES"; `SAFETY.md` says it is not security-audited.
- **Ecosystem:** the `dsh-plugin` GitHub topic, community distributions (`cocode-agency/cocode`, `CheChc/deepencode` TUI, `openma-ai/Martty` ACP-client TUI) and `nexu-io/open-design` (~100k stars) all describe themselves as DeepSeek Harness plugins or distributions [verified via GitHub search; not deeply inspected].

**Architecture** (`docs/architecture.md`) [verified]:
- Built on **Cordis** ("plugins contribute services, typed events, and reversible effects to a shared context"). *Every* part (model adapter, tool registry, session log, the agent loop itself) is a plugin, replaceable from config; there is "no privileged core".
- A running `dsh` is a plugin tree composed from **profiles** (`web`, `headless`, `sdk`, `sdk-minimal`, `acp`; user-defined profiles like `tui`) made of ordered **bundles** + `cordis.patch.yml` + `--patch` overlays. `dsh --profile web --dump-config` prints the tree.
- Electron desktop app; Python and TypeScript SDKs launch `dsh --profile sdk`.
- Core packages: `core/session` (append-only `SessionEvent` log), `core/system-prompt`, `core/tools`, `core/agent`, `core/agent-loop`, `core/scope`, `llm/llm`.
- **Event domains:** session events (durable), agent events (`agent/*`, live interception), capability events (`fs/*`, `tools/*`, …).
- **Invariant: "Model-visible means logged."** Every model request must be reconstructable from the session log. Sessions are versioned `session.vN.jsonl[.zstd]` with forward migrations; fork, resume and transcripts derive from the log.
- **Capability seams:** each capability = Service Definition + Provider + Consumer. Examples:
  - filesystem, subprocess, sandbox, approval, compaction, skills, MCP, LSP, jobs, schedule, browser-use, computer-use, SSH;
  - SSH providers make the same tools run on a remote host.

**Tools / packages** (package tree) [verified]:
- Shell and files: `tool-bash` (+ persistent), `tool-fs`, `tool-str-replace-editor`, `tool-fs-search`.
- Web, planning and interaction: `tool-web`, `tool-todo`, `tool-ask-user`, `plan-mode`, `tool-goal`.
- Agents, jobs and scheduling: `tool-skill`, `tool-subagent` (+ control), `tool-jobs`, `tool-schedule`, `tool-workflow` (PTC: programmatic tool calling in sandboxed Node/Python), `tool-lsp`.
- Experimental: `tool-agent-team`, `tool-worktree`, `tool-terminal`, `tool-session-query`.

**Sub-agents** (`docs/subsystems/subagent.md`) [verified]:
- A unified activation API with pluggable backends: `subagent-spawn-in-process`, `subagent-fork-in-process`, **`subagent-acp`** (any ACP agent as a child process), **`subagent-claude-code`** (fresh unattended Claude Code session), **`subagent-codex`**, `subagent-dsh-sdk`.
- Capability flags per backend: `outputSchema`, `depthLimit`, `toolFilter`, `persona`.
- Experimental **agent teams**: roster, mailbox, tasks.

**Permissions:**
- Sandbox seam: `read-only | workspace-write | danger-full-access` (deliberately the same vocabulary as Codex). Backends: Linux bwrap/Landlock, macOS Seatbelt, Windows ACL, SSH.
- Approval seam: closed, **fail-closed** outcomes `allowed-once | rejected | cancelled | unavailable`; per-session `ask` / `never`.
- Permission presets (`docs/subsystems/approval.md`, `sandbox.md`) [verified].

**Compatibility bridges** [verified]:
- `experimental/hooks-claude-code` and `hooks-codex` run existing `hooks.json` files (command hooks only).
- `experimental/claude-code-mods` runs Claude Code mods.
- `context/agent-instructions` loads `AGENTS.md`/`CLAUDE.md` chains with a byte budget.
- `context/tmux-context` (opt-in) tells the model which tmux session, window and pane it is in.

**Headless and protocols** (`docs/cli-help.md`) [verified]:
- `dsh headless "task"` with `--json` (NDJSON run events) and `--session-id`.
- `dsh --profile sdk`: **stdio JSON-RPC 2.0 over NDJSON** (`packages/sdk/protocol/README.md`).
- `dsh --profile acp` (ACP server).
- `dsh web`: browser UI with a typed RPC "API gateway" (`docs/api-gateway.md`).

### 6b. Not official, but commonly confused
- **"deepseek-tui"**: `Hmbown/deepseek-tui` / `Hmbown/DeepSeek-TUI` now redirect to **`codewhale-hq/Codewhale`** ("Open-source Rust agent engine and terminal client… provider choice, tools, approvals and receipts", ~41k stars). It is **not** a DeepSeek AI product. A `Hmbown/homebrew-deepseek-tui` tap still exists [verified via GitHub API].
- **`esengine/DeepSeek-Reasonix`** (Go, ~36k stars): community coding agent with a DeepSeek preset, permission levels, plan mode, file rewind, ACP, extensions [verified README; not deeply inspected].
- **`lessweb/deepcode-cli`** ("Deep Code", optimised for deepseek-v4) and **`itmisx/deepx-code`**: smaller community CLIs [GitHub search only].
- `deepseek-ai/awesome-deepseek-agent` / `awesome-deepseek-integration` are curated link lists, not harnesses.

**Takeaways for iOS:**
- "Model-visible means logged" as a hard invariant.
- Capability seams (FS / subprocess / sandbox providers swappable, so iSH-local and SSH-remote are the same tool behind different providers).
- Subagent backends that are *other agents over ACP*.
- Hook and mod compatibility bridges to inherit the Claude Code / Codex ecosystem.

---

## 7. Briefly: other harnesses

### OpenCode [verified]
- `sst/opencode` now resolves to **`anomalyco/opencode`** ("The open source coding agent", TypeScript, default branch `dev`, ~213k stars). Docs in `packages/web/src/content/docs/*.mdx`.
- **Client/server split:** "When you run `opencode` it starts a TUI and a server. The TUI is the client that talks to the server." The server is HTTP with an **OpenAPI 3.1 spec** at `/doc` and **SSE** at `/event` and `/global/event`. Endpoints include:
  - `/session` CRUD, `/session/status`, `/session/:id/children`, `/fork`, `/abort`, `/revert`, `/summarize`, `/permissions/:permissionID`;
  - `/message` (sync), `/prompt_async`, `/command`, `/shell`, `/tui/*` control.
- `opencode serve` (headless; basic auth via `OPENCODE_SERVER_PASSWORD`; mDNS), `opencode attach <url>` (TUI to a remote server), `opencode web`, `opencode run`, ACP (`acp.mdx`), JS SDK generated from OpenAPI (`server.mdx`, `cli.mdx`, `sdk.mdx`).
- Agents: primary (Build, Plan) cycled with Tab; subagents (General, Explore, Scout) via @mention.
- Permissions: `allow | ask | deny` per tool and pattern.
- Plugins: JS/TS in `.opencode/plugins/` or npm, subscribing to bus events such as `tool.execute.before/after`, `permission.asked`, `session.idle`, `session.compacted`, `experimental.session.compacting`, `file.edited`.
- Tools: bash, edit, write, read, grep, glob, apply_patch, skill, webfetch, websearch, question, lsp.
- **Most "multiplexer-friendly" design:** one server, many sessions, an SSE bus, mDNS discovery.

### Goose [verified]
- `block/goose` resolves to **`aaif-goose/goose`** (Rust, ~55k stars).
- Architecture: interface (desktop/CLI) → agent → **extensions = MCP servers**. "The interface can also create multiple agents to handle different tasks concurrently" (`documentation/docs/goose-architecture/goose-architecture.md`).
- `goose acp` / **`goose serve`** (an ACP server that Goose Desktop normally runs in the background; can run remotely with TLS + cert fingerprint) (`guides/remote-goose-server.md`).
- Goose can also *delegate to* ACP agents such as Claude Code or Codex as "providers".
- Headless `goose run -t …`. **Recipes and subrecipes** (parallel). Subagents.
- Permission modes: Completely Autonomous / Manual / **Smart Approval** / Chat Only.
- Auto-compaction plus fallback strategies. `.goosehints` context file.

### Gemini CLI [verified]
- `google-gemini/gemini-cli` (TypeScript, ~107k stars).
- Headless: `-p` / non-TTY with `--output-format json|stream-json` (events `init`, `message`, `tool_use`, `tool_result`, …) (`docs/cli/headless.md`).
- **ACP mode** `gemini --acp` (`docs/cli/acp-mode.md`). Gemini CLI was ACP's first reference agent [uncertain historical detail].
- Subagents exposed to the main agent as tools of the same name (`docs/core/subagents.md`).
- Hooks: `SessionStart/End`, `BeforeAgent/AfterAgent`, `BeforeModel/AfterModel`, `BeforeToolSelection`, `BeforeTool/AfterTool`, `PreCompress`, `Notification` (`docs/hooks/index.md`).
- Sandbox: macOS Seatbelt profiles or Docker/Podman/gVisor(runsc)/LXC (`docs/cli/sandbox.md`).
- Checkpointing via a shadow git repo in `~/.gemini/history/<hash>`.
- Also: trusted folders, policy engine, extensions, skills, auto-memory, GEMINI.md.

### Aider [verified]
- `Aider-AI/aider` (Python, ~49k stars). **Last release v0.86.0 on 2025-08-09; last push 2026-05-22.** It is in maintenance mode compared with the others.
- Architecture: single-process pair programmer. Repo-map, git auto-commits, edit formats, watch-mode via code comments.
- No sub-agents, hooks or protocol server. Scripting is via the CLI (`--message`) and the Python API [uncertain: not re-verified in this pass].
- Its contributions (repo map, edit formats, git-as-undo) have been absorbed by the others.

### Notable 2025–2026 entrants and related infrastructure (encountered, lightly verified)
- **Agent Client Protocol** `agentclientprotocol/agent-client-protocol` (Rust, ~4.4k stars): JSON-RPC over stdio, "connecting any editor to any agent". Implemented by Gemini CLI, Hermes, Goose, OpenCode, DeepSeek Harness and Reasonix.
- **OpenClaw** `openclaw/openclaw` (~392k stars): personal agent built on Pi's SDK (Pi README). Hermes ships `hermes claw migrate`.
- **Codewhale** (ex-deepseek-tui), **DeepSeek-Reasonix**, **Command Code**, **gptme**, **Open Interpreter** (now "a coding agent for open models").
- **Agent multiplexers:**
  - `herdrdev/herdr` (Rust, ~43k stars): "the runtime your coding agents live on". Background server, multiple SSH machines in one window, panes marked working / blocked / idle, CLI + socket API, **agent-side integration contract**.
  - `manaflow-ai/cmux` (Ghostty-based macOS terminal for agents, CLI + socket API).
  - Also nodeterm, seance, tortie.
- **OpenMinis** `OpenMinis/OpenMinis` (~5.1k stars): your upstream.

---

## 8. What an on-device iOS agent app should adopt (ranked)

Context assumed: an OpenMinis fork with a Swift app process hosting the agent loop, an iSH (x86/aarch64-emulated Alpine) shell as the execution tool, MCP client, sub-agents, `SKILL.md` skills, `SOUL.md`, slash commands and memory files. iOS constraints:
- no background daemons beyond short task windows;
- no `fork/exec` of host binaries outside iSH;
- no Seatbelt or bubblewrap available to you (the app is already sandboxed by iOS);
- frequent suspension and network loss;
- touch UI.

### Tier 1: adopt now (high value, low cost, iOS-friendly)

1. **An append-only JSONL session log with a tree (Pi model), and "model-visible means logged" (DeepSeek invariant).**
   - Every entry gets `id` + `parentId` + `type`. The active leaf defines context.
   - Persist system-prompt sections and tool-loadout changes as entries, so any request is reconstructable (Pi `session-format.md`; dsh `architecture.md`).
   - Add `compaction` entries (summary + `firstKeptEntryId`; originals retained) and `branch_summary` entries.
   - UI: long-press any message → "Branch from here" / "Edit & resend" (Pi `/tree`); "Fork to new chat" (Pi `/fork`, Codex `thread/fork`, OpenCode `/session/:id/fork`).
   - Why it suits iOS: crash/suspend-safe (fsync per line), cheap iCloud sync of append-only files, and enables replay or resume after the app is killed mid-turn. Mark an interrupted tail on resume, as dsh does.

2. **A headless agent protocol: a Pi-style command/event vocabulary carried as JSON-RPC, with ACP as the external face.**
   - Internally, define the agent core API as commands:
     - prompt and queue control: `prompt`, `steer`, `follow_up`, `abort`, `clear_queue`;
     - state: `get_state`, `get_messages`, `get_tree`;
     - session ops: `fork`, `clone`, `compact`, `set_model`, `switch_session`.
   - Define events: `agent_start`, `turn_start`, `message_update` (deltas), `tool_start`/`tool_end`, `turn_end`, `agent_end`, **`agent_settled`** (Pi `rpc.md`, `json.md`).
   - **Approvals and questions must be server→client *requests* with IDs**, not events (Codex `item/*/requestApproval`; Hermes `approval`/`clarify` requests; Pi extension-UI records).
   - On reconnect, return `inflight` + `open_requests` so a re-opened app or a remote viewer can re-render pending prompts (Hermes TUI gateway).
   - Expose it over:
     - (a) an in-process Swift API for your own UI;
     - (b) a local socket or WebSocket (behind a token) for a companion/desktop manager;
     - (c) **ACP** so Zed/JetBrains/other harnesses can drive the phone agent, and so the phone can drive ACP agents.
   - Mirror Codex's practice of **generating JSON Schema from the protocol types** and versioning it.

3. **Hooks with the Claude Code / Codex event names and the JSON stdin/stdout contract.**
   - Events: `SessionStart`, `UserPromptSubmit`, `PreToolUse` (can block or modify), `PostToolUse`, `PermissionRequest`, `PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop`, `Stop`, `SessionEnd`, `Notification`.
   - Handler types that make sense on iOS:
     - `command`, executed in iSH;
     - `http`;
     - `prompt` (LLM-evaluated);
     - `mcp_tool`.
   - Support `if:`-style permission-rule matchers (`Bash(git *)`).
   - This lets users bring existing `hooks.json` (DeepSeek Harness proves this bridging is feasible: `hooks-claude-code`, `hooks-codex`).

4. **Context-file conventions.**
   - Load `AGENTS.md` (+ `AGENTS.override.md`) as the primary project file and `CLAUDE.md` as a fallback, walking root → cwd with a byte budget (Codex 32 KiB). Insert provenance headers (Hermes).
   - Keep **`SOUL.md` as a separate identity slot** that sub-agents do *not* inherit (Hermes); sub-agents *do* inherit project context files.
   - Support `SYSTEM.md` / `APPEND_SYSTEM.md` overrides (Pi).

5. **Approval policy as an explicit, per-session mode, separate from what tools can do.**
   - Expose named modes: **Ask (default) / Accept edits / Plan (read-only) / Auto (classifier or "smart") / Don't ask (deny unapproved; for scheduled and background runs) / Full access**. These are Claude Code's mode names; Hermes and Goose offer the same spectrum.
   - Add rules `allow | ask | deny` with patterns (OpenCode, Claude Code). Deny always wins.
   - Add Codex-style decisions: `accept`, `acceptForSession`, `decline`, plus **"always allow this prefix"**, persisted as an execpolicy-like prefix rule with a justification.
   - Separate policies for unattended contexts (Hermes `cron_mode`, `unattended_mode`, `single_query_mode` default `deny`). This is essential for `minis-scheduled`-style jobs.
   - Fail closed when no answerer is present (DeepSeek `unavailable`).

6. **Skills = slash commands, with progressive disclosure.**
   - One `SKILL.md` format (agentskills.io) that is both model-invocable and `/name` user-invocable.
   - Frontmatter: `disable-model-invocation`, `allowed-tools`, `context: fork` (run as a forked sub-agent) (Claude Code skills).
   - Only names and descriptions go in the prompt (Hermes ~3k-token index).

7. **Sub-agent definitions as markdown files** (Claude Code `.claude/agents/*.md`; Pi example `agents/*.md`; Codex `.codex/agents/*.toml`).
   - Fields: `name`, `description`, `tools`/`disallowedTools`, `model`, `permissionMode`, `maxTurns`, `skills`, `mcpServers`, `background`, `output_schema`.
   - Defaults: fresh context, summary-only return, depth limit (Hermes default flat; Claude 3), concurrency cap (Hermes 10).
   - **Background delegation that posts results back as a new message** (Hermes) instead of blocking the turn. This suits iOS suspension well.

### Tier 2: adopt next (high value, more work)

8. **Bounded, agent-managed memory with capacity headers, plus session search.**
   - Hermes `MEMORY.md` / `USER.md` with character limits and a usage-percentage header: writes fail when full, forcing consolidation.
   - A frozen snapshot at session start (cache-friendly).
   - FTS search over past sessions (SQLite FTS5 runs fine on iOS).
   - Optional background consolidation like Codex's two-phase memories pipeline.

9. **Self-authored skills plus a curator** (Hermes `skill_manage` + Curator).
   - The agent writes new skills after hard tasks; an idle-time job consolidates and archives (never deletes), with an audit log.
   - Gate writes behind approval.

10. **Steering vs follow-up queues** (Pi, Codex `turn/steer`, Hermes `session.steer`).
    - Users on a phone type while the agent runs; specify whether a message interrupts after the current tool batch or waits for completion.

11. **Checkpoints and rewind for files** (Claude Code checkpointing; Hermes and Gemini shadow git; Reasonix rewind).
    - In iSH, a shadow git repo snapshot before `write`/`edit`/destructive commands, at most one per directory per turn (Hermes rule).

12. **Tool-exposure tiers and tool search.**
    - Keep the default tool list tiny (Pi: read/bash/edit/write; Claude Code dropped Glob/Grep on POSIX).
    - Defer MCP and device tools behind `tool_search` (Pi, Claude Code, Codex).
    - Optionally add a **codemode/PTC** tool: JS (JavaScriptCore is native on iOS!) or Python-in-iSH scripts that call tools and return only the final output (Pi codemode via QuickJS; Hermes `execute_code`; dsh PTC; Claude Code Workflows).
    - JavaScriptCore makes codemode unusually cheap on iOS.

13. **Capability seams for execution.**
    - Abstract `fs`, `subprocess` and `sandbox` behind providers (DeepSeek Harness) so the same `bash`/`read`/`edit` tools can target **local iSH**, **SSH remote hosts** (dsh `ssh/*`, Hermes SSH backend), or **cloud sandboxes** (Hermes Modal/Daytona).
    - This is how "on-device and remote agents" become uniform.

14. **Sub-agent backends that are other agents.**
    - Like dsh `subagent-acp` / `subagent-claude-code` / `subagent-codex`, and Goose ACP providers: allow a sub-agent to be "Codex on my Mac via app-server" or "any ACP agent over SSH".
    - The phone becomes the orchestrator.

### Tier 3: consider / situational
- **Agent teams with mailboxes / message boards** (Claude Code agent teams, Codex agent-message-board, Hermes Kanban, dsh agent-team). Useful once the manager exists; otherwise heavy.
- **Plugins / packages** bundling skills + agents + hooks + MCP (Claude Code plugins, Pi packages). Distributing via git URLs is feasible; npm is not on-device.
- **Push-event channels** (Claude Code channels): an MCP server that injects external events (webhooks, iMessage) into a running session. On iOS this maps to notifications or Shortcuts → app intent → `prompt`.
- **Structured output** (`--json-schema`, `--output-schema`, Hermes `output_schema`) for sub-agents and scheduled jobs.

### Irrelevant or low value on iOS
- **OS-level process sandboxes** (Seatbelt, Landlock, bubblewrap, Windows ACL, Docker/Podman/gVisor). iOS already sandboxes the app, and iSH is a userspace emulator.
  - *Do* keep the *vocabulary* (`read-only`/`workspace-write`/`full`) and enforce it in your file and shell tool layer: path allowlists inside `/var/minis/...`, plus network gating at the tool level. You cannot rely on the kernel.
- **Long-lived supervisor daemons** (Claude Code supervisor, Codex app-server daemon, herdr server) **on the device**. iOS will suspend you.
  - Put daemons on the *remote* side and have the phone attach. On-device, persist state so "resume on foreground" is cheap (append-only log + inflight replay).
- **Multi-platform messaging gateway** (Hermes). Not needed in-app; the phone *is* the chat client. A remote Hermes or OpenClaw gateway could be one of the managed remote agents.
- **Worktree isolation** (Claude Code `isolation: worktree`, `EnterWorktree`): only relevant if users do git-heavy coding in iSH; low priority.
- **TUI-specific features** (differential rendering, tmux extended keys, Ink): irrelevant except for an optional "terminal view".
- **Cordis-style hot-swappable plugin trees and npm-distributed TS extensions**: on iOS you cannot load arbitrary native code. JS extensions in JavaScriptCore with a restricted API are possible, but App Store review (guideline 2.5.2, executable code) is a real constraint [uncertain: depends on your distribution channel]. Prefer declarative extensions (skills, hooks run in iSH, MCP servers) over in-process code.
- **LSP tools**: low value on a phone.

---

## 9. Machine protocols a tmux-style multi-agent manager can drive or observe

Requirement: a manager that groups on-device and remote agents, shows per-agent state (working / blocked / idle / done), lets you peek, reply, approve and attach, and survives disconnects.

| Harness | Drive (send prompts, control) | Observe (stream state/events) | Approvals over the wire | Multi-session per process | Remote transport | Notes |
|---|---|---|---|---|---|---|
| **Codex** | app-server JSON-RPC: `thread/start/resume/fork`, `turn/start/steer/interrupt` | notifications `turn/*`, `item/*`, deltas; `thread/list`, status-change tracking | **Yes**, server→client `requestApproval`, `requestUserInput` | Yes (threads) | stdio, `unix://`, `ws://` + token auth; daemon for remote/mobile | Best-specified. Generated TS/JSON Schema. `codex exec --json` for one-shot. |
| **OpenCode** | HTTP: `POST /session`, `/message`, `/prompt_async`, `/command`, `/abort`, `/fork` | **SSE `/event`**, `/global/event`; `GET /session/status` (all sessions) | **Yes**, `permission.asked` event + `POST /session/:id/permissions/:id` | Yes (server hosts many sessions, child sessions) | HTTP + basic auth, mDNS discovery, `opencode attach <url>` | Easiest to integrate from Swift (URLSession + SSE). OpenAPI spec. |
| **Claude Code** | `claude -p --input-format stream-json --output-format stream-json` (per session); Agent SDK (TS/Py); `claude --bg`, `attach`, `stop`, `respawn` | `stream-json` events; **`claude agents --json --all`** (state, status, `waitingFor`) | via SDK `canUseTool` / `--permission-prompt-tool` (MCP); stream-json `permission_denied` | Supervisor hosts many background sessions | Local CLI; Remote Control (Anthropic-hosted relay to claude.ai and mobile apps) | No open network server API. A remote manager would run an SSH shim that wraps `claude agents --json` + SDK. |
| **Pi** | `pi --mode rpc` JSONL commands (`prompt`, `steer`, `follow_up`, `abort`, `fork`, `switch_session`…) | JSONL events incl. `agent_settled`; `get_state` | Extension-UI request/response records; no built-in permission prompts | One session per RPC process (switchable) | stdio only (wrap with SSH or a socket bridge); experimental pi-server/pi-protocol (CBOR, Unix socket) | Simplest, cleanest protocol to wrap. |
| **Hermes** | TUI-gateway JSON-RPC (`prompt.submit`, `session.steer`, `session.interrupt`, `session.branch`, `subagent.steer`…); ACP; OpenAI-compatible HTTP | `message.delta`, `tool.*` events; `session.active_list`, `delegation.status`; reconnect `inflight` + `open_requests` | **Yes**, server→client `approval`/`clarify`/`sudo`/`secret` requests; `client.capabilities` handshake | Yes; multiple clients per live session | stdio or **WebSocket**; HTTP API server | Best reconnect semantics; explicitly multi-client. |
| **DeepSeek Harness** | `dsh --profile sdk` JSON-RPC over NDJSON stdio; ACP; `dsh headless --json` | session events / SDK notifications; web `/api` | Approval seam answerers (UI / ACP automation) | Yes (web host) | stdio; web (HTTPS, token) | Developer preview; protocol churn expected. Has opt-in tmux-context. |
| **Gemini CLI** | `gemini --acp`; `-p --output-format stream-json` | stream-json events | ACP `session/request_permission` | Per ACP connection | stdio | Use via ACP. |
| **Goose** | `goose acp`, **`goose serve`** (ACP server, remote with TLS) | ACP updates | ACP permission requests | Yes | stdio; HTTP(S) for `serve` | Desktop already uses this client/server split. |
| **Aider** | CLI flags only | stdout | n/a | n/a | n/a | Drive only via a PTY (tmux-style screen scraping). |

### Recommendations for the multi-agent manager
1. **Normalise everything to one internal "agent adapter" interface:**
   - Methods: `start(session?)`, `prompt(text, mode: steer|followUp)`, `interrupt()`, `fork(at)`, `respond(requestId, decision)`.
   - Observables: `state` (`working | blocked(waitingFor) | idle | done | failed | stopped`), `events`, `openRequests`.
   - Write adapters in this order:
     - (1) **ACP**, which covers Gemini, Goose, Hermes, OpenCode, dsh and Reasonix in one adapter;
     - (2) **Codex app-server**;
     - (3) **OpenCode HTTP/SSE**;
     - (4) **Claude Code** (SDK or stream-json + `claude agents --json`);
     - (5) **Pi RPC**;
     - (6) **PTY fallback** for anything else (tmux-style pane with heuristics).
2. **Adopt the herdr state contract for PTY-hosted agents.** Set env vars (`*_PANE_ID`, `*_SOCKET_PATH`) and accept self-reports of `idle | working | blocked`, a **resume command**, and a **release** on exit (herdr "Add Herdr support to your agent"). Make your own iOS agent emit the same reports when run inside a manager.
3. **Use Claude Code's state vocabulary** (`working`, `blocked`, `done`, `failed`, `stopped` + `waitingFor: permission prompt | input needed | …`) as the canonical row state. It is the most precise taxonomy published.
4. **Remote agents:**
   - Run them under their own daemons (Codex app-server daemon, `opencode serve`, `goose serve`, Hermes gateway WebSocket, `claude --bg` supervisor).
   - Connect from iOS over SSH tunnels or WebSocket with tokens.
   - **Never** expose unauthenticated WebSockets: Codex docs warn its non-loopback WS allows unauthenticated connections by default during rollout.
5. **Your on-device agent as a managed agent:**
   - Expose your protocol via ACP + your RPC on a local socket.
   - Because iOS suspends, publish a *durable* state file (last state, open requests, resume token) so a remote manager can tell "suspended" from "dead". Add a `suspended` state that none of the desktop tools need.
6. **Approvals are the killer feature on mobile.** Aggregate every agent's open approval requests (Codex `requestApproval`, OpenCode `permission.asked`, Hermes `approval`, ACP `request_permission`, Claude `--permission-prompt-tool`) into one inbox with push notifications. Answer with `once | session | always-prefix | deny`.

---

## 10. Open questions and caveats
- **Claude Code** is closed source. Behaviour is from docs only, and the SDK ↔ CLI control protocol is not published as a stable spec.
- **Codex** app-server WebSocket transport is "experimental and unsupported". The app-server "isn't supported for production workloads" per `/docs/mcp-server.md`.
- **DeepSeek Harness** is a developer preview with breaking changes promised, and its protocols will move. The "~248k stars" figure is a GitHub API snapshot.
- **Pi**'s `pi-server` / `pi-protocol` / `pi-durable` packages are explicitly experimental. The stable surfaces are `--mode json`, `--mode rpc` and the SDK.
- **Hermes** docs are extensive and fast-changing. Feature names (Kanban, Curator, `/journey`) were current at research time.
- **Project/org renames observed:**
  - `badlogic/pi-mono` → `earendil-works/pi`;
  - `sst/opencode` → `anomalyco/opencode`;
  - `block/goose` → `aaif-goose/goose`;
  - `Hmbown/deepseek-tui` → `codewhale-hq/Codewhale`.

  GitHub redirects these; update any hard-coded URLs.

---

## 11. Source index (primary)

**Pi:**
- https://github.com/earendil-works/pi
- `README.md`, `packages/coding-agent/README.md`
- `packages/coding-agent/docs/{how-pi-works,rpc,rpc-commands,json,sessions,session-format,compaction,extensions,skills,mcp,cli,configuration,security,sdk,tmux}.md`
- `packages/coding-agent/examples/extensions/subagent/README.md`
- `packages/{durable,server,protocol}/README.md`

**Hermes:**
- https://github.com/NousResearch/hermes-agent
- `README.md`
- `website/docs/developer-guide/{architecture,programmatic-integration,context-compression-and-caching,session-storage}.md`
- `website/docs/user-guide/features/{delegation,skills,memory,curator,hooks,cron,kanban,context-files}.md`
- `website/docs/user-guide/{security,checkpoints-and-rollback}.md`
- `website/docs/reference/toolsets-reference.md`

**Claude Code:**
- https://code.claude.com/docs/llms.txt
- `/docs/en/{tools-reference,sub-agents,agent-teams,agent-view,cross-session-messaging,workflows,hooks,skills,headless,cli-reference,permission-modes,sandboxing,sessions,memory,context-window,remote-control,channels}.md`
- `/docs/en/agent-sdk/overview.md`, `/docs/en/plugins/overview.md`, `/docs/en/plugins/mods/overview.md`
- https://github.com/anthropics/claude-code

**Codex:**
- https://github.com/openai/codex
- `codex-rs/docs/protocol_v1.md`
- `codex-rs/core/README.md`
- `codex-rs/app-server/README.md`, `codex-rs/app-server-daemon/README.md`
- `codex-rs/execpolicy/README.md`
- `codex-rs/memories/README.md`
- `codex-rs/thread-store/README.md`
- `codex-rs/core/src/tools/handlers/` (tree)
- https://learn.chatgpt.com/docs/{app-server,non-interactive-mode,mcp-server,sandboxing,permission-modes,agent-approvals-security,agent-configuration/agents-md,agent-configuration/subagents,hooks,codex-sdk}.md

**DeepSeek Harness:**
- https://github.com/deepseek-ai/deepseek-harness
- `README.md`, `SAFETY.md`
- `docs/{architecture,cli-help,api-gateway}.md`
- `docs/subsystems/{subagent,agent-team,approval,sandbox,skills,compaction,tools,claude-code-mods}.md`
- `packages/{subagent/subagent-acp,subagent/subagent-claude-code,context/agent-instructions,context/tmux-context,sdk/protocol,experimental/hook-protocol}/README.md`

**OpenCode:**
- https://github.com/anomalyco/opencode
- `packages/web/src/content/docs/{server,agents,tools,permissions,plugins,cli}.mdx`

**Goose:**
- https://github.com/aaif-goose/goose
- `documentation/docs/goose-architecture/goose-architecture.md`
- `documentation/docs/guides/remote-goose-server.md`
- `documentation/docs/guides/managing-tools/goose-permissions.md`
- `documentation/docs/tutorials/headless-goose.md`

**Gemini CLI:**
- https://github.com/google-gemini/gemini-cli
- `docs/cli/{headless,acp-mode,sandbox,checkpointing}.md`
- `docs/core/subagents.md`
- `docs/hooks/index.md`

**Aider:** https://github.com/Aider-AI/aider (`README.md`, releases API)

**Other:**
- ACP: https://github.com/agentclientprotocol/agent-client-protocol
- herdr: https://github.com/herdrdev/herdr, https://herdr.dev/docs/add-herdr-support/
- cmux: https://github.com/manaflow-ai/cmux
- Codewhale: https://github.com/codewhale-hq/Codewhale
- Reasonix: https://github.com/esengine/DeepSeek-Reasonix
- OpenMinis: https://github.com/OpenMinis/OpenMinis
