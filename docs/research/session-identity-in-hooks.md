---
status: verified
verified_against: Claude Code 2.1.272 (darwin arm64), 2026-09-16
---

# Session identity inside a Stop hook

**Question.** One machine runs several concurrent Claude Code sessions in different
Rooms. When `hooks/bus-wake.sh` fires, how does it know *which* session it is?

**Answer.** Read `session_id` off the hook's stdin JSON. It is documented, it is
present on `Stop`, it is unique per concurrent session, and it survives `--resume`,
`--continue` and `/compact`. It does **not** survive `/clear` or `--fork-session` —
both mint a new id, which is a cursor-GC problem, not a correctness problem.

Everything below marked **Verified** was captured from the installed binary by
registering a throwaway `Stop` hook that dumped its raw stdin and environment. The
user's `~/.claude/settings.json` and this repo's hooks were not touched.

---

## 1. The `Stop` hook stdin contract

**Verified.** Real payload, captured verbatim from a `Stop` hook on 2.1.272:

```json
{
  "session_id": "89492c3e-90b6-4cca-a8c5-01fa3b2fbd39",
  "transcript_path": "/Users/sukh/.claude/projects/-private-tmp-.../89492c3e-90b6-4cca-a8c5-01fa3b2fbd39.jsonl",
  "cwd": "/private/tmp/.../probe/wd",
  "scratchpad_dir": "/private/tmp/.../89492c3e-90b6-4cca-a8c5-01fa3b2fbd39/scratchpad",
  "prompt_id": "2b634b59-1b2c-489b-af0b-77eecd094ff2",
  "permission_mode": "default",
  "hook_event_name": "Stop",
  "stop_hook_active": false,
  "last_assistant_message": "ok6",
  "background_tasks": [],
  "session_crons": []
}
```

All five fields the brief asked about are present: `session_id`, `transcript_path`,
`cwd`, `hook_event_name`, `stop_hook_active`.

The documented common-field set — `session_id`, `prompt_id`, `transcript_path`,
`cwd`, `scratchpad_dir`, `permission_mode`, `effort`, `hook_event_name`, plus
`agent_id`/`agent_type` on subagent events — is at
<https://code.claude.com/docs/en/hooks>. `stop_hook_active` is documented in the
guide (<https://code.claude.com/docs/en/hooks-guide>) with the recommended
early-exit idiom.

Two deltas worth knowing:

- **`last_assistant_message`, `background_tasks`, `session_crons` are undocumented**
  on the hooks reference page but were observed on every `Stop` payload. Do not
  build on them.
- **`effort` is documented as a common field but was absent** from the observed
  payload (the probe ran with `--setting-sources ""`, so no effort setting applied).
  Treat every field except `session_id`/`hook_event_name` as optional; parse with
  `jq -r '.field // empty'`.

**Verified: `async: true` changes nothing.** The repo's Stop hook is registered
`async: true, asyncRewake: true`. A hook registered that way received a byte-identical
field set, including `session_id`. The async path is safe to key on.

---

## 2. Environment variables in a hook process

**Verified.** With the parent environment scrubbed (`env -i`), Claude Code itself sets
exactly these in a hook process on 2.1.272:

| Variable | Notes |
|---|---|
| `CLAUDE_CODE_SESSION_ID` | **Equals stdin `session_id`.** Verified identical on every event. **Undocumented.** |
| `CLAUDE_PROJECT_DIR` | Documented. Project root. |
| `CLAUDE_PID` | PID of the `claude` process. Undocumented. Useful for liveness (§5). |
| `CLAUDE_ENV_FILE` | Documented. Per-session, path contains the session id. |
| `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_MESSAGING_SOCKET`, `CLAUDE_CODE_MESSAGING_TOKEN` | Undocumented. |

`CLAUDE_PLUGIN_ROOT` is documented and already used by this repo; it did not appear
in the probe only because the probe loaded no plugin.

> **There is no `CLAUDE_SESSION_ID`.** I checked the hooks reference page directly:
> neither `CLAUDE_SESSION_ID` nor `CLAUDE_CODE_SESSION_ID` is listed among the
> documented hook environment variables (the page lists `CLAUDE_PROJECT_DIR`,
> `CLAUDE_PLUGIN_ROOT`, `CLAUDE_PLUGIN_DATA`, `CLAUDE_CODE_REMOTE`,
> `CLAUDE_CODE_BRIDGE_SESSION_ID`, `CLAUDE_EFFORT`, `CLAUDE_PLUGIN_OPTION_<KEY>`).
> `CLAUDE_CODE_SESSION_ID` is real but undocumented.

**Recommendation: read stdin `session_id`, not the env var.** stdin is the documented
contract; the env var is not. Use the env var only as a fallback when stdin is
unavailable (e.g. a helper spawned by the hook rather than the hook itself).

**Verified: the id is always an RFC-4122 UUID** — all 8 ids observed across the probe
matched `^[0-9a-f-]{36}$`, including the one Claude minted itself after `/clear`. It
is safe to use unescaped as a filename or JSON object key. Validate it anyway before
interpolating into a path: it arrives from outside the hook.

---

## 3. Stability of `session_id`

**Verified** — each row is a real run, reading the id back out of the hook payload.

| Action | `session_id` | `SessionStart.source` |
|---|---|---|
| fresh start | new | `startup` |
| `--session-id <uuid>` | **exactly the uuid you pass** | `startup` |
| `--resume <id>` | **unchanged** | `resume` |
| `--continue` | **unchanged** | `resume` |
| `/compact` | **unchanged** | `compact` |
| `/clear` | **CHANGES** | `clear` |
| `--fork-session` | **CHANGES** | `fork` |

The `/compact` case is the reassuring one: `SessionStart` fires a second time with
`source: "compact"` carrying the *same* id, so a cursor keyed on `session_id`
survives compaction untouched.

The `/clear` case is the trap. Observed sequence: `SessionEnd` on the old id, then
`SessionStart` with `source: "clear"` and a **brand-new** id, in the same process and
same cwd. So:

- A cursor keyed on the old id is **orphaned** (leak, not loss).
- The new session starts with **no cursor**, so on its first `Stop` it must be
  initialised to "tail" — current end of spool — and **not** to zero, or it replays
  the entire spool history as unread.

Same reasoning applies to `--fork-session` and `/branch`.

**Not tested / unknown:** whether restarting a session from the IDE (VS Code
extension "restart") preserves the id. The probe drove the CLI only. The IDE almost
certainly goes through one of the paths above — but which one is **undocumented**,
so do not assume. The cursor design must tolerate an id changing at any time, and
the "new id ⇒ start at tail" rule makes that safe.

**Known exception — Claude Code Remote.** Under CCR the id changes *every turn*: each
user turn is a fresh process with a fresh `session_id`. Use
`CLAUDE_CODE_REMOTE_SESSION_ID` in preference when it is set. See §6, where Anthropic's
own plugin does exactly this.

Docs corroborating the flag semantics: `--fork-session` "Create a new session ID
instead of reusing the original" (<https://code.claude.com/docs/en/cli-reference>);
the `source` value set `startup|resume|clear|compact|fork`
(<https://code.claude.com/docs/en/hooks-guide>).

---

## 4. Is `cwd` / `CLAUDE_PROJECT_DIR` viable instead? No.

**Verified by direct experiment.** Two sessions launched concurrently in the *same*
directory produced:

```
Stop  sid=2fcbb55f-561b-48d4-8c81-89b41a9915bb  cwd=/…/probe/wd
Stop  sid=ba589657-9d40-47e2-b5be-8f61dcdec981  cwd=/…/probe/wd
```

Identical `cwd`, identical `CLAUDE_PROJECT_DIR`, distinct `session_id`. Keying on
the directory collapses both sessions onto one cursor — which is the *current* bug
(theft) in a new costume, and exactly the "two tickets, one checkout" case from the
brief.

**The platform offers nothing better than `session_id`.** It is the only per-session
value that is documented, unique across concurrent sessions, and stable across the
common continuation paths. `transcript_path` is 1:1 with it but is a derived path the
docs explicitly warn against depending on; `prompt_id` changes every turn; `CLAUDE_PID`
is per-process, not per-session, and is reused by the OS.

---

## 5. Garbage collection — and why `SessionEnd` is not enough

**Verified: `SessionEnd` does not fire when the session is killed.** A session
`SIGKILL`ed mid-turn emitted `SessionStart`, `UserPromptSubmit`, `Stop` — and no
`SessionEnd`. On a clean exit it does fire, carrying a `reason` (observed: `"other"`
in print mode).

So a `SessionEnd`-only cleanup leaks on every crash, `kill -9`, closed terminal and
lost SSH connection. Corroborating evidence that this leak is real and that the
platform does not clean up after itself: **`~/.claude/session-env/` on this machine
holds 215 stale per-session directories**, some dating to August.

**Recommended GC for the cursor file**, belt-and-braces:

1. `SessionEnd` hook removes the cursor for its `session_id` — handles the clean case.
2. A TTL sweep on every `Stop`: drop any cursor whose `updated_at` is older than, say,
   7 days. This is what actually catches the killed sessions.
3. Optionally store `CLAUDE_PID` alongside the cursor and treat `kill -0 $pid` failure
   as dead. Cheap, but PIDs are reused and this env var is undocumented — use it as a
   hint to sweep sooner, never as the sole criterion. If you do, copy Claude Code's own
   defence against PID reuse: `~/.claude/sessions/<pid>.json` stores
   `{"pid":…, "sessionId":…, "procStart":"Wed Sep 16 08:27:39 2026", …}` — pid **plus
   process start time**, so a recycled pid does not read as the same process. Note also
   superpowers' nuance when probing: `catch (e) { return e.code === 'EPERM'; }` —
   `EPERM` means the process exists but is not yours, i.e. alive.

A leaked cursor costs a few dozen bytes and is harmless; a cursor deleted while its
session is alive silently loses that session's Notices. **Bias GC toward leaking.**

---

## 6. Prior art

**The best reference is Anthropic's own `security-guidance` plugin**, which keeps
per-session state on disk and has clearly already hit every problem above:
`~/.claude/plugins/marketplaces/claude-plugins-official/plugins/security-guidance/hooks/session_state.py`.

It answers all four of our questions, and it agrees with the conclusions above:

- **Key** — stdin `session_id`, one file per session:
  `~/.claude/security/security_warnings_state_<key>.json` (state dir overridable via
  `CLAUDE_CONFIG_DIR`). Not cwd, not pid.
- **Sanitisation** — the key is scrubbed before it becomes a filename, with a comment
  that is worth copying wholesale:

  ```python
  # CC session ids are UUIDs (sanitization is a no-op for them), but nothing in
  # the hook protocol guarantees that, so strip path separators and anything
  # else that could escape the state dir, and bound the length.
  return re.sub(r"[^A-Za-z0-9._-]", "_", str(key))[:128]
  ```

- **Garbage collection — a 30-day mtime sweep, not `SessionEnd`.**
  `cleanup_old_state_files()` deletes state/lock files whose mtime is older than 30
  days, fired probabilistically: `if random.random() < 0.1: cleanup_old_state_files()`
  — a 10% chance per hook run, so the sweep cost is amortised instead of paid on
  every `Stop`. The plugin registers no `SessionEnd` hook at all. This is independent
  confirmation of §5: the reference implementation does not trust an end-of-session
  signal to fire. (Claude Code itself uses the other idiom for the same job — a stamp
  file, `~/.claude/.last-cleanup`, holding one ISO timestamp.)
- **Concurrency** — read-modify-write is wrapped in `with_locked_state()`, which takes
  an `fcntl.flock(LOCK_EX)` on a sibling `.lock` file, with a documented no-locking
  fallback on Windows. Two hooks *will* race; it locks rather than hoping.

**One important caveat it surfaces**, which the docs do not:

```python
# In CCR each user turn is a new CC process with a fresh session_id; the
# remote session ID is stable across those restarts. Prefer it so the
# pending-warnings sweep and any unprocessed touched_paths survive.
key = os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID") or session_id
```

**In Claude Code Remote, every user turn is a new process with a new `session_id`.**
Under CCR a plain `session_id` cursor resets each turn. `CLAUDE_CODE_REMOTE_SESSION_ID`
is stable across those restarts; the hooks reference also lists a related
`CLAUDE_CODE_BRIDGE_SESSION_ID` and a `CLAUDE_CODE_REMOTE` flag. Adopt the same
precedence — `CLAUDE_CODE_REMOTE_SESSION_ID` if set, else stdin `session_id` — and the
"new id starts at tail" rule keeps even that case from replaying the spool.

**Prior art in this repo: none.** No hook under `hooks/` reads `session_id`,
`CLAUDE_CODE_SESSION_ID` or `transcript_path`, and no `SessionEnd` hook is registered
anywhere. The existing `~/.config/truxo-bus/cursors.json` is keyed by **Room**, machine-globally:

```json
{
  "feat/driver-on-time-rating": "1789546316124-0",
  "sukhkainth-punjabsoft/lan-bus": "0",
  "truxo-inc/truxo-punjabsoft": "1789546233018-0"
}
```

**Correction worth knowing:** `bus-monitor.mjs` never touches `cursors.json`. The only
thing that writes it is the `bus-inbox` skill's bash block
(`skills/bus-inbox/SKILL.md`), which clobbers the whole file on each inbox read:
`jq '.rooms | with_entries(.value = .value.cursor)' … > cursors.json`. So this is a
machine-global, Room-keyed *read position advanced by whichever session last ran the
skill* — **a second theft vector of the same shape as the spool bug**, and one the
per-session redesign should sweep up rather than leave behind.

`hooks/bus-poll-rewake.sh` (the retired polling Stop hook, no longer in `hooks.json`)
shows the same mistake with a different key: `.bus-cursor-${DEV_NAME}` — per developer,
so two concurrent sessions on one machine clobber each other.

**Closest prior art to our actual problem: `ralph-loop`.** Its Stop hook keeps state
*project*-scoped at `.claude/ralph-loop.local.md` but stores the session id **inside**
the file as an ownership guard — and its comment is this exact bug:

```bash
# Session isolation: the state file is project-scoped, but the Stop hook
# fires in every Claude Code session in that project. If another session
# started the loop, this session must not block (or touch the state file).
STATE_SESSION=$(echo "$FRONTMATTER" | grep '^session_id:' | sed 's/session_id: *//')
if [[ -n "$STATE_SESSION" ]] && [[ "$STATE_SESSION" != "$HOOK_SESSION" ]]; then exit 0; fi
```

It reads the id the way we should: `HOOK_SESSION=$(echo "$HOOK_INPUT" | jq -r '.session_id // ""')`.
Its weakness is GC — it `rm`s only on normal completion, so a loop abandoned by closing
the terminal leaves a file that permanently no-ops every future session in that project.

### The landscape in one table

| Pattern | Who | GC |
|---|---|---|
| state keyed by stdin `session_id` | `security-guidance` — **the only one** | 30-day mtime sweep, 10% random trigger |
| session id as a guard *field* in project-scoped state | `ralph-loop` | `rm` on clean finish only; leaks on abandon |
| state keyed by `pid-timestamp` | superpowers brainstorm-server | owner `kill -0` poll + idle timeout |
| state keyed by pid **+ process start time** | Claude Code itself, `~/.claude/sessions/<pid>.json` | harness-internal |
| state keyed by session id, never collected | Claude Code's `session-env/` (215 dirs); `~/.claude/hooks/notify-desktop.sh` | none |
| state keyed by cwd/repo slug | truxo-bus `cursors.json`, `rooms.json` | none, by design |
| **`SessionEnd` cleanup hook** | **nobody on this machine** | — |
| **`.jsonl` byte-offset cursor** | **nobody** | — |

Three things that table is telling us:

- **Nobody uses `SessionEnd` for cleanup.** Not one plugin. Every `SessionEnd` string
  found on this machine is documentation or a validator's list of event names.
- **Nobody keeps a transcript read-offset.** The stripe plugin tails `transcript_path`
  but re-scans backwards from EOF every time rather than storing a cursor. So our
  spool-offset design has no precedent to copy — but also no precedent warning against it.
- **The official `plugin-dev` guidance is a trap.** Its hook-state examples use
  `/tmp/hook-state-$$` — but `$$` is the *hook subprocess* pid, which differs on every
  invocation, so those examples do not actually persist across events. Do not follow them.

---

## What this means for the fix

- Key Room bindings and spool cursors on **stdin `session_id`**, read in
  `bus-wake.sh` via `jq -r '.session_id'` from the payload it already receives on
  stdin but currently ignores. Prefer `CLAUDE_CODE_REMOTE_SESSION_ID` when set.
  Sanitise before using it as a path component.
- A cursor is a **byte offset (or line count) into an append-only spool**. Nothing is
  consumed, nothing is `mv`'d, so there is no theft — each session advances only its
  own offset.
- **An unknown `session_id` starts at the tail of the spool, not at zero.** This is
  the single rule that makes `/clear`, `--fork-session` and any undocumented IDE
  restart safe: a new identity sees only what arrives after it, instead of replaying
  history.
- Write cursors to a **separate file from the spool**, keyed by session id. Either one
  file per session (what `security-guidance` does — no contention) or one shared file
  guarded by `flock`. Do not do read-modify-write on a shared file unguarded: several
  sessions wake at once, which is the whole premise here.
- GC: the **TTL sweep is the load-bearing mechanism**; a `SessionEnd` hook is a nice
  fast path but cannot be relied on (§5). Fire the sweep probabilistically or off a
  stamp file, not on every `Stop`.
- Note `bus-wake.sh` currently runs `set -euo pipefail` and never reads stdin. Consume
  it (`input="$(cat)"`) before anything else, or the payload is lost.
- **Fix `cursors.json` in the same change.** It is machine-global and Room-keyed, and
  the `bus-inbox` skill clobbers the whole file on every read (§6). Even after the
  spool bug is fixed, two sessions reading their inboxes will still overwrite each
  other's read position. Same disease, different file.

## Sources

- <https://code.claude.com/docs/en/hooks> — common input fields, hook env vars
- <https://code.claude.com/docs/en/hooks-guide> — `stop_hook_active`, `source` values
- <https://code.claude.com/docs/en/cli-reference> — `--session-id`, `--resume`, `--continue`, `--fork-session`
- <https://code.claude.com/docs/en/sessions> — transcript layout, 30-day `cleanupPeriodDays` retention
- Everything labelled **Verified** — captured from `claude` 2.1.272 on darwin arm64,
  2026-09-16, via a temporary `Stop`/`SessionStart`/`SessionEnd`/`PreCompact` hook
  writing raw stdin and `env` to a scratch directory. Probe artifacts removed
  afterwards; no user or repo configuration was modified.
