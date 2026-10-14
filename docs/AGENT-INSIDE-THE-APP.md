# The agent inside the app

Written from the inside, on 2026-10-11, while working on this codebase from a chat session that the
app itself is hosting. Two halves: what it is actually like and what the code does to make it possible
(observed + verified against the source), then what I would want built into the app we are shipping.

---

## 1. What I have, and what it feels like

My situation: I am a language model in a conversation, and the conversation has **hands**. Concretely,
in this session I have used:

| capability | what it actually gave me |
|---|---|
| `shell_execute` | A real Alpine Linux (aarch64) with a persistent filesystem — `apk add`, `python3`, `git`, `ssh`, `curl`. Not a mock: I cloned repos, ran Python analyses over 300k lines of Swift, and pushed commits. |
| `file_read` / `file_write` / `file_edit` | Editing source directly, which is how every fix in this session was written. |
| `browser_use` | A real WebKit browser — I scraped the Hugging Face API to build the model-inspection feature, and read a resolved package's source straight from GitHub to verify an API before compiling against it. |
| `subagent_task` | Child sessions with their own tool loops. |
| `memory_write` / `memory_get` | Daily logs and a global file, so context survives compaction. |
| `minis-config` | Changing **this app's own settings**, with a confirmation sheet and a revertable audit log. |
| `minis-mcp-cli` | Calling MCP servers (GitHub, Supabase here) as if they were local tools. |
| `minis-scheduled` | Registering a future turn. |
| `apple-*` | HealthKit, HomeKit, Vision OCR, alarms, maps, speech, photos — the device's own frameworks. |
| `/var/minis/` | A **bidirectional shared directory** between the shell and the host app. This is the load-bearing detail. |

The single most important property is not any one tool — it is that **the loop closes**. I can form a
hypothesis, act, and *observe the real consequence*: read the compiler's error, install a build and read
the version back off the device, screenshot the page I just wrote. Everything in this session — forking
and rebranding an application, cross-compiling it on a CI runner, signing it on a desktop reached over a
VPN from a phone, installing it, and reading the resulting crash log — happened inside a chat window.

### Frictions I actually hit

These are the real ones, not hypotheticals:

1. **Each shell call is a new process.** No `cd`, no exported variables, no history. Every call
   reconstructs its own context, and anything stateful has to be a file.
2. **A 1000-character command limit.** Long work becomes "write a script, then run the script" — which is
   fine, but it is a tax paid constantly, and it silently pushes detail into files where it can be lost.
3. **Coarse exit codes.** A command that partially succeeded looks like one that failed. I spent real
   time this session parsing logs to answer "did the build fail, or did the *test* fail?".
4. **No interactive stdin.** Passwords and TUI apps need a human-opened terminal.
5. **Sub-agents cannot see this conversation.** A brief has to be self-contained and explicit, and they
   cost a full model run — so they are for bulk work, never for a quick check.
6. **I cannot see the app.** This is the big one. Every UI verification in this session went through the
   user pasting a screenshot. That is a human in the loop where a tool call should be — and it is exactly
   the bottleneck the app's own `Debug/` code already solves (§3).
7. **Long operations need polling.** A 35-minute build means a chain of "check again" waits, and the app
   must stay alive for any of it to continue.
8. **Nothing supervises a background job.** A scheduled turn dies with the app; a shell server started in
   one call needs care so it does not get SIGPIPE when the call ends.
9. **My own cost is invisible to me.** I cannot tell that I have made 40 tool calls without value, and
   nothing meters it.

---

## 2. How this codebase makes it possible

The mechanisms are not incidental; they are a coherent design, and worth naming so we can extend them
deliberately rather than stumble on equivalents.

- **The tool loop.** `Agent/Chat/AIChatViewModel+ToolDefinitions` declares the surface
  (`shell_execute`, `file_read/write/edit`, `read_image`, `browser_use`, `memory_*`, `task`, …),
  `+ToolPreflight` and `+ConcurrentTools` run it, `ToolLoopDetector` catches degenerate repetition, and
  `+Offloading` moves oversized results to files rather than into the context window. **`PerfProbe`
  measures the tools themselves**, per tool and per agent, with an explicit argument about its own cost.
- **The shell is a real Linux.** `iSH/` plus the Alpine rootfs in `deps/` gives the agent a POSIX
  environment *inside the app* — which is why package installation, Python, and SSH were available to me
  at all.
- **`/var/minis/` is the bridge.** `Shared/` exposes an app-group container to that rootfs. This is what
  turns "the agent has a shell" into "the agent and the app share a filesystem": I write a file, the app
  can serve it (`minis://`), and the user can preview it. **Removing this would gut the agent.**
- **Memory is ordinary files.** Daily logs and a global file, written by tools, read at session start.
  No vector store — durable, greppable, and inspectable by the user.
- **Sub-agents are first class.** `SubAgentStore`/`SubAgentDefinition` with their own stores and their
  own tool loops (`[T-sub-agents-v1]`).
- **MCP is plumbed in.** `Agent/Session/MCPOAuthDiscovery.swift` plus the CLI — third-party tools appear
  as local ones.
- **The app can modify its own configuration.** `minis-config` writes settings, and every write triggers
  an on-device confirmation plus an audit entry that can be reverted. This is the seed of *agent
  self-modification with consent*, and it is the pattern to generalise.
- **Skills are code-free capability.** `/var/minis/skills/<name>/SKILL.md` — instructions the agent loads
  at runtime. A new capability with no recompile, no IPA, no signing. (The webgame-port skill here works
  exactly this way.)
- **Traceability as a first-class artifact.** 1,036 distinct `[T-…]` tags, 3,946 uses. For an agent
  editing this codebase, those comments are the difference between guessing and knowing.

---

## 3. The discovery that matters most: the app already has an introspection server

While auditing for this document I found `src/ios/Debug/` — 15k lines that are **compiled only under
`#if DEBUG`** (23 of 25 files gate on it), and therefore **absent from every Release IPA we ship**:

| file | what it is |
|---|---|
| `DebugServer.swift` | A **TCP listener** (port 8321) with a C-socket accept loop. |
| `DebugJSONRPC.swift` + `DebugMethodRegistry.swift` | A JSON-RPC method surface. |
| `DebugViewInspector.swift` | **Reads the live SwiftUI/UIKit view tree.** |
| `DebugViewOverlay.swift` | Draws inspector overlays on the running app. |
| `AutoTouch.h/.m` | **Injects real touches, text input and scrolls** via private UIKit APIs. |
| `DebugScreenshotBuffer.swift` | An in-memory ring of screenshots, timestamped and labelled. |
| `DebugAuth.swift` | Token auth: `/pair` needs **on-device user approval**, then HMAC-SHA256-CTR envelopes, per-request nonce, ±120 s window, replay LRU, 30-day idle expiry. |
| `HangDetector`, `DebugRPCHangDetector`, `AgentRequestTrace`, `DebugRPCPerfTrace` | Liveness and latency instrumentation. |

Two details make this remarkable rather than merely useful:

1. The auth design is *serious* — pairing with user approval, encrypted envelopes, replay protection —
   and its spec lives in **`.claude/skills/debug-server/SKILL.md`**. The original developer wrote a
   **skill file so an AI agent could drive this server.** The "agent inside the app" is not a new idea
   here; it is an existing, working practice, just confined to development builds.
2. It binds `INADDR_ANY` and relies on the auth layer as the gate — reasonable for a debug surface,
   and the thing to re-examine before shipping any of it.

**So the capability I want already exists and is switched off in what we ship.** That reframes the work:
not "build an agent API", but "promote the debug surface into a supported, opt-in *Agent Access*
feature" — with the same pairing/auth design, off by default, audited, and visible in Settings.

---

## 4. What I would want built

Prioritised by how much they change what I can do, not by how easy they are.

### P0 — Give the agent eyes and hands on the app itself
A supported **Agent Access** surface (the `Debug/` machinery, release-safe and opt-in):

- `app_state` — current session id, model, provider, composer text, processing state, last error,
  thermal/memory, active panels. *Today I infer all of this from screenshots.*
- `app_view_tree` — the accessibility-shaped tree (`DebugViewInspector` already does the hard part), so
  I can assert "this control exists, with this label" instead of "the user says it's there".
- `app_screenshot` — a real screenshot on demand, plus the existing buffered ring for "what did it look
  like when it broke".
- `app_action` — a **narrowly enumerated** set of safe actions (navigate to screen, set composer text,
  tap a named control). Deliberately not arbitrary touch injection: that is a foot-gun to ship, and a
  named-action vocabulary is testable and auditable.
- `app_logs` — read the app's own log ring (the author already has `AppLogger` categories and
  `AgentRequestTrace`).

Consequence: every UI change in this project stops depending on a human screenshot, and "does the fix
work?" becomes a tool call.

### P0 — Make the build/deploy loop tools, not shell improvisation
We proved we can go from a source edit to an installed, verified build on the phone over a VPN. Today
that is ~10 hand-written `ssh` invocations per iteration, in my head. It should be:

```
build.start(commit) -> build_id          // CI
build.status(build_id) -> {state, errors: [structured], duration}
deploy.install(build_id) -> {installed_version}
app.smoke_test() -> {pass/fail per check}   // see below
```

Structured errors are the point: I want the compiler's message as data (file, line, code, message), not
a log to grep. That single change removes the most error-prone part of my day.

### P1 — Let the app test itself after install
The LoopLab batteries were the most valuable thing we built there, and they were all hand-rolled. Give
the app a **self-test manifest**: after an install, run a scripted set of checks (engine loads, a prompt
completes, dictation pipeline returns text, picker lists N models) and report a table. The agent should
be able to add a check as part of every fix it makes. That is how "we changed something" becomes "we
know it still works".

### P1 — Self-configuration as a first-class, provenance-carrying API
Extend what `minis-config` started: providers, MCP servers, sub-agents, skills, model groups, and
scheduled jobs should all be settable through **schema-validated tools** that (a) validate before
applying, (b) show the user a diff, and (c) record the change with the agent as the author, revertable in
one tap. Right now I write config by string manipulation and hope. Also expose the *reading* side as
JSON — a **capability manifest**: entitlements, installed models, their sizes, available MCP servers,
skills, permissions, storage. The Local Inference settings page is the human version of this document;
the agent needs the machine-readable one.

### P1 — Jobs that survive suspension
The app's scheduling is best-effort while the process lives, and my long work (a 35-minute build) hangs
on that. iOS gives us the substrate: `LongRunningIntent` with `performBackgroundTask` (and Shortcuts
automations for guaranteed wake-ups). A supervised job with a durable record — what it was, what it
produced, what it needs next — would let an agent work across hours instead of one turn.

### P2 — Artifacts as first-class objects
I produce files constantly (scripts, docs, images, builds). They should be addressable, previewable in
the conversation, and attached to the message that produced them, with provenance. The offload system is
half of this; the missing half is a registry the agent and the user can both browse ("what did this
session make?"), and it is the natural home for **everything a build produced**.

### P2 — Hot-reloadable behaviour
Skills already prove the model: capability as data, loaded at runtime. Extend it to
**prompts/tools/soul**, with versioning and an easy revert, so the agent can improve its own behaviour
without an IPA cycle. Concretely: a skill or prompt edit should be testable *in-session* (define, run,
compare), and only afterwards promoted.

### P2 — Mutation of the app itself, and its honest boundary
Inside a static IPA there are two clearly different mutation surfaces:

- **Runtime surface (no rebuild):** settings, providers, MCP, sub-agents, skills, prompts/soul, model
  library, scheduled jobs. Data, not code. The agent can do all of this today, and should be able to do
  it through validated, auditable tools.
- **Code surface (rebuild):** source changes. This is *not* impossible — **we closed that loop in this
  session** (edit → CI → sign → install → verify → read the app's own report). What makes it viable is
  the reproducibility, not the mechanism: pinned dependencies, a deterministic build, a signing path,
  and a version read-back.

So the honest answer to "how much can the agent change?" is: **everything, with a rebuild in between,
and we have already proven the loop**. The work worth doing is making that loop cheap and observable —
build/deploy/smoke-test as tools — not inventing a scripting layer inside the app to avoid it. A
half-measure (an interpreter that patches behaviour at runtime) would be less predictable than the
rebuild we already have, and would complicate a codebase whose main virtue is that it is legible.

### P3 — A mint of small things
- Meter my own efficiency: calls per result, tokens per fix, P50/P95 tool latency, surfaced to me.
- A "what changed since the last turn" digest, so I can re-orient after compaction from facts rather
  than from my own summary.
- Tool-call budget hints, so I notice when a task is ballooning.
- Deterministic UI snapshots for regression: screenshot + view tree, diffed.
- Session search is already there (`minis-sessions-cli`); wire it as a memory source so I can recall
  *how* something was solved previously, with the commands that worked.

---

## 5. What this means for the app we are building

"Agent-native" is a real design axis, and this codebase is already far along it — the tool loop,
the shared filesystem, memory-as-files, skills-as-data, and an auth'd introspection server. The gap is
not ambition; it is that the most valuable parts are either DEBUG-only (the introspection surface) or
hand-rolled by the agent every time (build/deploy/verify).

If we take one thing from this document into Nabla's design: **the agent, the app, and the user share one
observable world**. The app should expose its own state as data (for the agent), its own actions as named
operations (for testing), and its own configuration with provenance (for the user). Then an agent working
inside it stops guessing — and so do we.
