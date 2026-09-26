# Repository Guidelines

## Project structure

Swift 6 package, macOS 14+. Five targets, layered so that each one depends only
on the ones above it:

- `Sources/AgentHQKit/` — domain model. **No I/O.** If a type here needs a
  socket, a file, or a clock it cannot control, it belongs in another target.
- `Sources/AgentHQTransport/` — `LocalSocketTransport` and `SSHTunnel`. Both
  resolve to a local unix socket path. Plus `MachineShell`, the one other way
  onto a machine: a short script in, bytes out (invariant 14).
- `Sources/AgentHQHerdr/` — the herdr wire protocol. Knows one socket path.
  Must stay ignorant of machines, SSH, and the fleet.
- `Sources/AgentHQFleet/` — `MachineSession` per machine, plus `FleetStore`.
  The only place that knows there is more than one machine.
- `Sources/AgentHQApp/` — SwiftUI menu bar.

Tests live in `Tests/<Target>Tests/`.

## Commands

- `swift build` — compile all targets
- `swift test` — run the Swift Testing suite
- `swift run AgentHQApp` — launch the menu-bar app in development
- `./build-app.sh` — rebuild `AgentHQ.app` and install it over
  `/Applications/AgentHQ.app`, restarting it if it was running
  (`--no-install` builds the repo copy only)

**`swift build` does not update `AgentHQ.app`.** The two are separate
binaries: `swift build` writes a debug build under `.build/`, and the bundle
carries its own release build that only `build-app.sh` refreshes. A change
verified with `swift build` and `swift test` is not in the app the user is
looking at, and there is nothing on screen to say so — the menu bar item looks
identical either way. It has already cost one round of "the fix doesn't work",
where the binary under test was hours older than the fix.

So when a change is to be checked in the running app rather than in tests, run
`./build-app.sh`. It installs over `/Applications/AgentHQ.app` — the copy the
user launches — and restarts it. It used to stop at the repo copy, and the
`/Applications` one went on running a build from before the fix.

`swift run AgentHQApp` is the other way to see a change, and it does use the
fresh build — but it runs a second menu bar item alongside the installed one,
and `TunnelReaper` means the one starting up will tear down the other's
tunnels. Run one or the other, not both.

## Invariants

These are the decisions the architecture exists to protect. Changing one is a
design discussion, not a refactor.

1. **`AgentID` is a faithful echo of herdr's pane id.** It goes back on the
   wire verbatim. Never join a machine id into it — use `AgentRef`.
2. **Machine reachability is not agent state.** An unreachable machine shows as
   unreachable, with its agents marked stale. It never renders as its agents
   having crashed.
3. **Never fabricate state.** Degraded is shown as degraded, with a reason. An
   absent reason line is better than a guessed one.
4. **`AgentHQHerdr` does not import `AgentHQFleet` or `AgentHQTransport`.** The
   package graph enforces this; keep it that way.
5. **One request, one connection.** herdr replies once and closes; reusing a
   connection works exactly once and then fails with EPIPE forever. Verified
   against herdr 0.9.0 / protocol 22. `events.subscribe` is the exception and
   holds its connection open.
6. **Never block an actor on a socket read.** The subscription read has no
   timeout, because silence between events is normal. Running it on an actor
   keeps that actor isolated inside the read forever and deadlocks everything
   that calls it. It runs on a dedicated thread; closing the fd is what stops
   it, since a blocking read cannot be cancelled from outside.
7. **Decode against the live protocol, not an older client.** Protocol 22
   renamed fields a 17-era client still reads — `label` for `name`,
   subscription objects for bare strings. A wrong name decodes to zero or
   empty, not to an error.

8. **`state_change_seq` is the staleness stamp, and it is not `revision`.**
   An earlier version of this file said protocol 22 renamed one to the other.
   That was wrong, and wrong in exactly the direction the invariant above
   warns about. Measured against herdr 0.9.1:

   - `agent.get` and `agent.list` return **both**, with different values
     (253 and 8 on the same pane).
   - `revision` does not track agent state. It sits unmoved through sending
     text, running a command, renaming a pane, an agent being detected in it,
     and that agent going blocked.
   - `state_change_seq` moves on agent state changes and is **herd-wide**: two
     panes driven through alternating changes yield one rising sequence
     (230/232/234 interleaved with 231/233/235). Each agent keeps its own
     stamp from that clock, which is what makes a per-agent comparison valid.
   - It appears **only** on `agent.get` / `agent.list`. Neither
     `session.snapshot`'s pane records nor `pane.get` carry it. A client that
     read it off a pane would get nil, default it to zero, compare zero to
     zero, and believe every staleness check passed.

   So `Agent.stateSeq` is optional and the guard **fails closed**: a row with
   no stamp refuses to send rather than sending unguarded.

   Which puts a standing obligation on every path that rebuilds a row: carry
   a stamp for the state being shown. A `pane_updated` event carries none, so
   `MachineSession` fetches the agent view whenever a pane's state disagrees
   with the list — not only when the pane has stopped. Fetching only for
   stopped panes left an agent that had just *started* working with no stamp
   until the next full resync, so Approve and Deny refused for that entire
   window, which is exactly when a freshly blocked agent needs answering. The
   condition is a state *change*, not an event, which is what keeps it
   affordable: a chatty working agent's output events carry the status it
   already has and cost nothing.

   And a refusal with no stamp is `unverifiable`, never `stateMoved`. The
   latter asserts a move that was never observed; reported that way it
   printed "It moved from working to working first — nothing sent."

9. **A pane record cannot say `done`. The agent view can.** herdr has two
   status enums, both spelled `agent_status`, both decoding cleanly:

   - `AgentStatus`, on `agent.get` / `agent.list`:
     `idle | working | blocked | done | unknown`
   - `PaneAgentState`, on a pane record — `session.snapshot`'s panes and every
     `pane_updated` event — drops `done`.

   So a finished run read off a pane arrives as `idle`. Not an error, not a
   missing field: a different valid value. Classified from panes alone,
   `.finished` was unreachable on every machine — agents went working, then
   idle, and the Completed section stayed empty forever. `agents(on:)` takes
   the status from `agentViews` and falls back to the pane only when a pane has
   no entry. Verified against herdr 0.9.1 and its own JSON schema.

   **And `done` does not mean "completed" — it means "completed and unseen."**
   herdr's own docs: *"`idle` and `done` both mean the agent is ready for
   input. The CLI/API uses the server's seen state to distinguish them;
   explicit focus commands mark the target seen, while reads do not. Each TUI
   client tracks viewed completions independently, so its Done badge can
   differ from the CLI or another client's badge."*

   Three consequences, each of which reads as a bug until you know this:

   - Reveal clears a row out of Completed. It calls `pane.focus`, which marks
     the agent seen, and `perform` resyncs straight after. That is correct.
   - Looking at a pane in herdr's own TUI does **not** clear it here. That
     client tracks its own viewed completions and never tells the server.
   - herdr's TUI showing a Done badge while `agent.list` says `idle` is not a
     disagreement to reconcile. They are two bookkeepers, and AgentHQ is an
     API client, so the server's is the only one it can read.

   `pane.read` does not mark an agent seen, which is what makes it safe to
   call on every stopped pane.

   **So `done` is not a state a client can wait for.** Measured against
   herdr 0.9.1, on the same pane, twice:

   - With Ghostty open and that pane focused: 150 samples across two full
     turns, `working` → `idle` → `working` → `idle`. `done` appeared **zero**
     times. herdr counts a focused pane as seen the moment the run ends.
   - With every Ghostty window closed: the same run reported `done` for about
     five seconds, then `idle` again once a client re-attached.

   And the `done` → `idle` flip happened at an **unchanged
   `state_change_seq`** (61 both times). The stamp tracks agent state, not
   seen state, so a client cannot detect the flip by watching it either.

   Which means a completion is only visible to AgentHQ as a **transition it
   watched**: `working` → a state that takes input (`idle` *or* `finished`).
   `MachineSession.completedUnseen` records exactly that and promotes the row,
   and `NotificationPolicy` announces on the same transition. Both are
   AgentHQ's own bookkeeping, which is what herdr's docs say a client is
   expected to keep — not a second opinion about herdr's. Nothing is
   fabricated: the session saw the agent working, and now it is not.

   Clearing it is then AgentHQ's job too, since herdr will go on saying
   `idle` either way: any intervention on the row calls `markSeen`, and
   starting a new turn drops it. So does a console window showing the row.

   The same goes for herdr's own `done`, which only a herdr client focusing
   the pane clears — with Ghostty closed, nothing does. `pane.focus` would,
   but it also drags an open Ghostty onto that pane. So `markSeen` records
   the `state_change_seq` of a finished row in `viewedDone`, and a `done`
   still carrying that stamp reads as `idle`. The stamp is safe to key on:
   the `done` → `idle` flip leaves it unchanged, and no new completion can
   arrive without a turn of `working` moving it first.

10. **Answering a prompt goes through `pane.send_keys`, never `agent.prompt`.**
   `agent.prompt` takes `target`, not `pane_id` — a `pane_id` is rejected with
   `missing field \`target\`` — and it refuses a blocked agent outright with
   `agent_blocked: requires interactive input`. Which is the whole case
   answering a prompt exists for.

11. **Never infer an answer key from which agent is running.** A provider-keyed
    table ("claude answers with enter") is wrong across versions and wrong
    across the several prompt shapes one agent uses. `PromptAffordances` reads
    the key out of the prompt's own footer, and offers nothing where the prompt
    named nothing. Most prompts are highlighted-row menus whose footer says
    "enter to confirm", and enter there takes whichever row is highlighted —
    which herdr reports nothing about. An Approve button there would be
    pressing enter and hoping.

    **The panel has one terminating action, End, and it is not an interrupt.**
    A Stop button that interrupted the current turn existed briefly and was
    removed at the user's request — stopping a turn is something you do while
    watching the agent, in the agent, and a second terminating button whose
    difference from End has to be explained every time is not worth the row.

    It is worth keeping why it could never have been a hardcoded `C-c`,
    because the same evidence governs End. Measured across herdr's agent
    manifests, `C-c` is the wrong interrupt key for most agents:
    `esc to interrupt` for claude, devin, letta and muse; `esc to stop` for
    droid; `ctrl+c to stop` for cursor; `ctrl+c to interrupt` for hermes; and
    opencode ships both, by mode — the second half of this invariant inside a
    single agent. For Claude Code the mistake is worse than a no-op: `esc`
    interrupts the turn, while `C-c` is its *quit* gesture and twice in a row
    exits the program.

    **End reads its keys the same way.** `Intervention.end` quits the agent
    and leaves the pane and its scrollback — `pane.close` would take the
    record of what the agent did with it, and the console depends on that.

    No manifest names an exit key; herdr's manifests carry detection rules
    only. So End reads the pane, in three steps, pressing nothing it was not
    told about:

    1. An exit key named in the footer is pressed once. pi's footer is
       `ctrl+c/ctrl+d clear/exit` — two **parallel lists**, where `ctrl+c` is
       *clear* and `ctrl+d` is exit. Scanning that line for "ctrl+c" and
       "exit" and pressing `C-c` is the trap, and on pi it exits nothing.
    2. Otherwise `C-c`, then re-read. A second press happens only because the
       pane asked for it — "Press Ctrl-C again to exit" is the authority, not
       a count and not a rule about which agent this is.
    3. Where nothing was offered, stop. One `C-c` has landed by then, so
       `exitNotConfirmed` names what was sent. It is the only
       `InterventionError` that reports a keystroke having gone out, and the
       only one allowed to.

    End takes no staleness stamp — like Reveal, its target is a pane id and
    means the same thing whatever state the agent is in. The panel's
    confirmation is the guard, and End is the one action that gets one.
12. **No continuous animation inside `MenuBarExtra`.** It causes the panel to
    flicker open and closed. Emphasis is static.

13. **A live subscription is not a live transport, and `activate` runs more
    than once.** `MachineSession` supervises both, separately, because each
    recovers from something the other cannot.

    The event subscription retries its own socket path forever with backoff.
    That is the right recovery for a herd restarting on the far side — the
    path still has a server behind it — and it is no recovery at all for the
    path itself going away. When the Mac changes networks, `ssh` exits on
    `ServerAliveCountMax` and takes the forwarded socket with it; the
    subscription then resubscribes to nothing, at a ten-second ceiling,
    indefinitely, while the session reports `reconnecting` — honestly, and
    permanently. The far side coming back changes nothing: there is no `ssh`
    left to carry it.

    So the supervisor asks `Transport.isHealthy()` before acting, and only
    rebuilds the transport when the socket has no server. It also retries
    `unreachable`, which nothing else did: a machine that was not routable at
    launch stayed that way until the user pressed Retry.

    Two consequences to preserve:

    - `LocalSocketTransport.isHealthy()` returns `true` unconditionally. A
      stopped local herdr is not a broken transport, and tearing the client
      down would replace a free recovery with a worse one.
    - `connect()` carries a generation stamp. `activate` can sit on `ssh` for
      twenty seconds, and a `stop` or a second rebuild can land inside that
      window; the attempt that finishes second must not install its client
      over the decision that overtook it.

14. **An agent's transcript is read from the agent's own file, never
    reconstructed from its terminal.** On the alternate screen — Claude Code in
    fullscreen — `pane.read` is one screenful (58 rows for 400 asked, herdr
    0.9.1), and herdr's socket cannot read files. So the console reads the
    session the agent's herdr integration reported in `agent_session`,
    through `MachineShell`: `/bin/sh` here, `ssh` to the tunnel's own
    destination elsewhere, so this Mac stays the degenerate case.

    - Where each agent keeps it, measured: claude `id` →
      `~/.claude/projects/*/<id>.jsonl`; codex `id` →
      `~/.codex/sessions/*/*/*/rollout-*-<id>.jsonl`; pi reports the `path`;
      opencode `id` → rows in `~/.local/share/opencode/opencode.db`, read with
      `sqlite3` or, where a host has none (stock WSL Ubuntu), `python3`.
    - `agent_session.value` came from a herdr server and goes into a shell
      script. An id must be `[A-Za-z0-9_-]`, a path an absolute `.jsonl` in
      single quotes; anything else gets no script at all.
    - Codex is read from `item_completed`, not `response_item`: its injected
      AGENTS.md arrives in the latter as a *user* message.
    - The console opens on the transcript for an agent with a reader, with
      the screen one click away. The live prompt exists only on the screen —
      a highlighted-row menu is answered by looking at it — so the screen is
      not removable, and while the agent waits its prompt is also pinned
      above the input: the whole prompt block (`Agent.prompt`), from the same
      output as the state — not the row's six-line `message`, which cut a
      four-option menu to its last options and lost the `❯` saying which one
      enter takes. An agent with no reader gets the screen only, not a guessed
      transcript.

    herdr pushes nothing when a pane's output changes — no event carries
    output, and `pane.output_matched` fires once — so the console polls, backing off while nothing moves and stopping while it is hidden.

15. **`pane_updated` is not an agent-state signal.
    `pane.agent_status_changed` is.** `pane_updated` follows the pane's
    `revision`, which an attached client's rendering drives. Measured against
    herdr 0.9.1 in a session with no client attached — every Ghostty window
    closed — a claude turn pushed `pane_updated` for `working` and **nothing**
    for the return to `idle`, while `agent.list` flipped at once. The row sat
    on Working, never became Completed, and the console showed the same.
    With a client attached it mostly worked, by accident, and not reliably:
    one run's `idle` arrived five seconds late and its `working` never came.

    `pane.agent_status_changed` fired for both transitions, with and without
    a client. It is dotted on the wire, unlike every other event name, and it
    carries the status alone. Two constraints shape how it is used:

    - It requires a `pane_id` (`missing field pane_id` without one), so it
      cannot be a global subscription. `MachineSession` keeps the watched set
      equal to its agent list, and `LiveHerdrClient` reopens the subscription
      when that set changes — silently, since nothing failed.
    - One unknown `pane_id` fails the whole subscribe with `pane_not_found`.
      That is treated as a drop: the watches are forgotten, the reconnect
      resyncs, and the resync supplies a set of panes that exist.

    herdr does not replay what happened while a subscription was being
    reopened. So while any agent is working, the supervisor tick compares
    `agent.list`'s stamps with the rows and resyncs on a difference — working
    is the one state whose missed exit leaves a row lying.

## Decisions kept on record

**`StateClassifier` does not defer to `agent.explain`.** Measured against
herdr 0.9.0 by fabricating each case in a throwaway pane: cursor's approval
prompt comes back `blocked` / `approval_prompt`, but an open question, a merge
conflict, and a 429 with a retry-after all come back `idle` with no matched
rule. herdr models none of the states that are ours, so explain could at most
second-opinion the blocked half — which already arrives free in
`agent_status`, while `PromptAffordances` also says *which key* answers. One
more round trip per stopped pane (~115ms across a tunnel) to learn less.
`explain.matched_rule` stays the upgrade path if approval detection proves
wrong in practice. What the measurement did change: herdr scopes its rules to
`bottom_non_empty_lines(n)`, at most 20, so the classifier reads 12 non-empty
lines — wide enough, and no wider than herdr's own.

## Style

Four-space indent, standard Swift API naming. Preserve Swift 6 concurrency
guarantees with `Sendable`, actors, and explicit isolation — do not reach for
`@unchecked Sendable` or `nonisolated(unsafe)` to make a warning go away.
No formatter or linter is configured; match the surrounding source.

Comments explain *why*, especially where a decision looks arbitrary but is
paying for a bug someone already hit. Do not comment what the code says.

## Testing

Swift Testing (`import Testing`), behavior-focused `@Suite` / `@Test`
descriptions, `#expect` assertions. Name files `*Tests.swift`. A test name
should read as the claim it defends.

Run `swift test` before submitting.

## Porting from Shepherd

[Shepherd / herdr-manager](https://github.com/sxp4931/herdr-manager) is MIT and
is the reference for the herdr protocol and the design token layer. When you
port a file:

1. Keep the MIT copyright notice at the top of the ported file.
2. Add it to the ported list in `NOTICE`.
3. Do not port its single-machine assumptions along with it — the adapter takes
   a socket path and returns machine-agnostic values.

## Commits and PRs

Concise, descriptive subjects. Explain user-visible impact, protocol or
security implications, and what you validated. Link the Linear issue.

Never commit credentials, socket files, journals, or unredacted agent output.
