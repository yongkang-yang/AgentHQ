# herdr protocol notes

What herdr actually does, measured, and the bugs each fact already cost.
`AGENTS.md` states the rules; this file is the evidence behind them, by
invariant number. Measured against herdr 0.9.0 / 0.9.1, protocol 22, unless a
section says otherwise. Re-measure before relying on any of it against a newer
herdr.

## Connections (invariants 5, 6)

herdr replies once and closes. Reusing a connection works exactly once and then
fails with EPIPE forever. `events.subscribe` is the exception and holds its
connection open.

The subscription read has no timeout, because silence between events is normal.
Running it on an actor keeps that actor isolated inside the read forever and
deadlocks everything that calls it. A blocking read cannot be cancelled from
outside, so closing the fd is what stops it.

## Decoding against protocol 22 (invariant 7)

Protocol 22 renamed fields a 17-era client still reads — `label` for `name`,
subscription objects for bare strings. A wrong name decodes to zero or empty,
not to an error.

## `state_change_seq` vs `revision` (invariant 8)

An earlier version of `AGENTS.md` said protocol 22 renamed one to the other.
That was wrong, in exactly the direction invariant 7 warns about.

- `agent.get` and `agent.list` return **both**, with different values (253 and
  8 on the same pane).
- `revision` does not track agent state. It sits unmoved through sending text,
  running a command, renaming a pane, an agent being detected in it, and that
  agent going blocked.
- `state_change_seq` moves on agent state changes and is **herd-wide**: two
  panes driven through alternating changes yield one rising sequence
  (230/232/234 interleaved with 231/233/235). Each agent keeps its own stamp
  from that clock, which is what makes a per-agent comparison valid.
- It appears **only** on `agent.get` / `agent.list`. Neither
  `session.snapshot`'s pane records nor `pane.get` carry it. A client that read
  it off a pane would get nil, default it to zero, compare zero to zero, and
  believe every staleness check passed.

A `pane_updated` event carries no stamp. Fetching the agent view only for
panes that had *stopped* left an agent that had just started working with no
stamp until the next full resync, so every guarded action refused for that
whole window. Fetching on a state *change*, not on every event, is what keeps
it affordable: a working agent's output events carry the status it already has.

A refusal with no stamp once reported itself as `stateMoved` and printed "It
moved from working to working first — nothing sent." That is why it is
`unverifiable`.

## `done`, and the two status enums (invariant 9)

herdr has two status enums, both spelled `agent_status`, both decoding cleanly
(verified against herdr 0.9.1 and its own JSON schema):

- `AgentStatus`, on `agent.get` / `agent.list`:
  `idle | working | blocked | done | unknown`
- `PaneAgentState`, on a pane record — `session.snapshot`'s panes and every
  `pane_updated` event — drops `done`.

Classified from panes alone, `.finished` was unreachable on every machine:
agents went working, then idle, and the Completed section stayed empty forever.

### `done` means "completed and unseen"

herdr's own docs: *"`idle` and `done` both mean the agent is ready for input.
The CLI/API uses the server's seen state to distinguish them; explicit focus
commands mark the target seen, while reads do not. Each TUI client tracks
viewed completions independently, so its Done badge can differ from the CLI or
another client's badge."*

Three consequences, each of which reads as a bug until you know this:

- Reveal clears a row out of Completed. It calls `pane.focus`, which marks the
  agent seen, and `perform` resyncs straight after. That is correct.
- Looking at a pane in herdr's own TUI does **not** clear it here. That client
  tracks its own viewed completions and never tells the server.
- herdr's TUI showing a Done badge while `agent.list` says `idle` is not a
  disagreement to reconcile. They are two bookkeepers, and AgentHQ is an API
  client, so the server's is the only one it can read.

`pane.read` does not mark an agent seen, which is what makes it safe to call on
every stopped pane.

### `done` is not a state a client can wait for

Measured on the same pane, twice:

- With Ghostty open and that pane focused: 150 samples across two full turns,
  `working` → `idle` → `working` → `idle`. `done` appeared **zero** times.
  herdr counts a focused pane as seen the moment the run ends.
- With every Ghostty window closed: the same run reported `done` for about five
  seconds, then `idle` again once a client re-attached.

The `done` → `idle` flip happened at an **unchanged `state_change_seq`** (61
both times). The stamp tracks agent state, not seen state, so a client cannot
detect the flip by watching it either.

Hence AgentHQ's own bookkeeping. `MachineSession.completedUnseen` records a
watched `working` → `idle`/`finished` transition and promotes the row;
`NotificationPolicy` announces on the same transition. Any intervention, a new
turn, or a console window showing the row clears it.

herdr's own `done` is cleared only by a herdr client focusing the pane — with
Ghostty closed, nothing does. `pane.focus` would, but it also drags an open
Ghostty onto that pane. So `markSeen` records the `state_change_seq` of a
finished row in `viewedDone`, and a `done` still carrying that stamp reads as
`idle`. Safe to key on: the flip leaves the stamp unchanged, and no new
completion can arrive without a turn of `working` moving it first.

## `agent.prompt` (invariant 10)

`agent.prompt` takes `target`, not `pane_id` — a `pane_id` is rejected with
``missing field `target` `` — and it refuses a blocked agent outright with
`agent_blocked: requires interactive input`, which is the whole case answering
a prompt exists for.

## Interrupt and exit keys (invariant 11)

Measured across herdr's agent manifests, `C-c` is the wrong interrupt key for
most agents: `esc to interrupt` for claude, devin, letta and muse; `esc to
stop` for droid; `ctrl+c to stop` for cursor; `ctrl+c to interrupt` for hermes;
and opencode ships both, by mode. For Claude Code the mistake is worse than a
no-op: `esc` interrupts the turn, while `C-c` is its *quit* gesture and twice
in a row exits the program.

No manifest names an exit key; herdr's manifests carry detection rules only.
pi's footer is `ctrl+c/ctrl+d clear/exit` — two **parallel lists**, where
`ctrl+c` is *clear* and `ctrl+d` is exit. Scanning that line for "ctrl+c" and
"exit" and pressing `C-c` exits nothing on pi. Claude Code answers a first
`C-c` with "Press Ctrl-C again to exit"; that sentence is the authority for a
second press. The algorithm is in `MachineSession.endConversation`.

A Stop button that interrupted the current turn existed briefly and was removed
at the user's request: stopping a turn is done while watching the agent, in the
agent, and a second terminating button whose difference from End needs
explaining every time was not worth the row.

## Subscription vs transport (invariant 13)

When the Mac changes networks, `ssh` exits on `ServerAliveCountMax` and takes
the forwarded socket with it. The subscription then resubscribes to nothing, at
a ten-second ceiling, indefinitely, while the session reports `reconnecting` —
honestly, and permanently. The far side coming back changes nothing: there is
no `ssh` left to carry it. Quitting and relaunching was the only recovery,
which is how it was found. Before the supervisor retried `unreachable`, a
machine that was not routable at launch stayed that way until Retry.

`activate` can sit on `ssh` for twenty seconds, which is the window the
generation stamp in `connect()` covers.

## Transcripts (invariant 14)

On the alternate screen — Claude Code in fullscreen — `pane.read` is one
screenful (58 rows for 400 asked, herdr 0.9.1), and herdr's socket cannot read
files. Where each agent keeps its transcript, measured:

- claude `id` → `~/.claude/projects/*/<id>.jsonl`
- codex `id` → `~/.codex/sessions/*/*/*/rollout-*-<id>.jsonl`, read from
  `item_completed`, not `response_item`: its injected AGENTS.md arrives in the
  latter as a *user* message
- pi reports the `path`
- opencode `id` → rows in `~/.local/share/opencode/opencode.db`, read with
  `sqlite3` or, where a host has none (stock WSL Ubuntu), `python3`

herdr pushes nothing when a pane's output changes: a pane writing a line every
half second raised no `pane_updated`, and `pane.output_matched` fires once on
its first match and never again. So the console polls.

The pinned prompt was once the row's six-line `message`, which cut a
four-option menu to its last options and lost the `❯` saying which one enter
takes. It is now the whole prompt block, `Agent.prompt`.

## `pane_updated` vs `pane.agent_status_changed` (invariant 15)

In a headless session (`herdr --session <name> server`, no client attached —
the same as every Ghostty window closed), a claude turn:

| | `agent.list` | `pane_updated` |
|---|---|---|
| turn starts | `working (5)` | pushed |
| turn ends | `idle (6)`, at once | **nothing** |

`pane_updated` follows `revision`, which an attached client's rendering drives.
With a client attached it mostly worked by accident, and not reliably: one
run's `idle` arrived five seconds late and its `working` never came.

`pane.agent_status_changed` fired for both transitions, with and without a
client. Its wire shape:

```json
{"event": "pane.agent_status_changed",
 "data": {"agent": "claude", "agent_status": "idle", "pane_id": "w1:p1", "workspace_id": "w1"}}
```

Dotted, unlike every other event name. Subscribing without a `pane_id` fails
with ``missing field `pane_id` ``; subscribing with an unknown one fails the
whole request with `pane_not_found`.

## `agent.explain` (decision)

`StateClassifier` does not defer to `agent.explain`. Measured against herdr
0.9.0 by fabricating each case in a throwaway pane: cursor's approval prompt
comes back `blocked` / `approval_prompt`, but an open question, a merge
conflict, and a 429 with a retry-after all come back `idle` with no matched
rule. herdr models none of the states that are ours, so explain could at most
second-opinion the blocked half — which already arrives free in
`agent_status`, while `PromptAffordances` also says *which key* answers. One
more round trip per stopped pane (~115ms across a tunnel) to learn less.
`explain.matched_rule` stays the upgrade path if approval detection proves
wrong in practice.

What the measurement did change: herdr scopes its rules to
`bottom_non_empty_lines(n)`, at most 20, so the classifier reads 12 non-empty
lines — wide enough, and no wider than herdr's own.
