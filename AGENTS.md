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
- `./build-app.sh` — rebuild `AgentHQ.app`, install it over
  `/Applications/AgentHQ.app`, and restart it if it was running
  (`--no-install` builds the repo copy only)

**`swift build` does not update the app the user is running.** It writes a
debug build under `.build/`; the bundle carries its own release build that only
`build-app.sh` refreshes, and nothing on screen tells the two apart. To check a
change in the running app, run `./build-app.sh`.

Do not run `swift run AgentHQApp` alongside the installed app: it adds a second
menu bar item, and its `TunnelReaper` tears down the other's tunnels.

## Invariants

The decisions the architecture exists to protect. Changing one is a design
discussion, not a refactor. The numbers are cited from source comments; keep
them stable. The measurements behind each are in
[`docs/herdr-protocol.md`](docs/herdr-protocol.md) — re-measure against a new
herdr before trusting any of them.

1. **`AgentID` is a faithful echo of herdr's pane id.** It goes back on the
   wire verbatim. Never join a machine id into it — use `AgentRef`.
2. **Machine reachability is not agent state.** An unreachable machine shows as
   unreachable, with its agents marked stale — never as its agents having
   crashed.
3. **Never fabricate state.** Degraded is shown as degraded, with a reason. An
   absent reason line is better than a guessed one.
4. **`AgentHQHerdr` does not import `AgentHQFleet` or `AgentHQTransport`.** The
   package graph enforces this; keep it that way.
5. **One request, one connection.** herdr replies once and closes; a reused
   connection fails with EPIPE. `events.subscribe` is the one exception.
6. **Never block an actor on a socket read, or on any other blocking wait.**
   The subscription read has no timeout, so it runs on a dedicated thread and
   is stopped by closing its fd.
7. **Decode against the live protocol, not an older client.** A wrong field
   name decodes to zero or empty, not to an error — check names against a
   captured reply.
8. **`state_change_seq` is the staleness stamp, and it is not `revision`.** It
   exists only on `agent.get` / `agent.list`, never on a pane record.
   `Agent.stateSeq` is optional and the guard **fails closed**: no stamp, no
   send, reported as `unverifiable`, never `stateMoved`. Every path that
   rebuilds a row must carry a stamp for the state it shows, so
   `MachineSession` fetches the agent view on every state *change* (not every
   event).
9. **Status comes from the agent view; a pane record cannot say `done`.**
   `agents(on:)` falls back to the pane only when there is no agent view.
   And `done` means "completed *and unseen*" by herdr's reckoning, so it is not
   a state to wait for. A completion is a `working` → `idle`/`finished`
   transition this session watched (`completedUnseen`); clearing it is
   AgentHQ's job (`markSeen`, `viewedDone`), since herdr goes on saying
   `idle` either way. `pane.read` does not mark an agent seen; `pane.focus`
   does.
10. **Answering a prompt goes through `pane.send_keys`, never
    `agent.prompt`.** `agent.prompt` refuses a blocked agent outright, and it
    takes `target`, not `pane_id`.
11. **Never infer a key from which agent is running.** `PromptAffordances`
    reads the answer key from the prompt's own footer and offers nothing where
    the prompt named nothing — enter on a highlighted-row menu takes whichever
    row is highlighted, which herdr does not report.

    The panel has one terminating action, **End**, and it is not an interrupt.
    End quits the agent and keeps the pane and its scrollback (never
    `pane.close`). It reads its keys the same way: a footer-named exit key
    once; otherwise `C-c`, and a second press only if the pane asks for it;
    otherwise stop with `exitNotConfirmed`, the only `InterventionError` that
    reports a keystroke having gone out. End takes no staleness stamp; the
    panel's confirmation is its guard.
12. **No continuous animation inside `MenuBarExtra`.** It makes the panel
    flicker open and closed. Emphasis is static.
13. **A live subscription is not a live transport, and `activate` runs more
    than once.** The subscription retries its own socket; the supervisor
    rebuilds the transport only when `Transport.isHealthy()` says the socket
    has no server, and retries `unreachable`. Preserve:
    - `LocalSocketTransport.isHealthy()` returns `true` unconditionally — a
      stopped local herdr is not a broken transport.
    - `connect()` carries a generation stamp, so an attempt overtaken by a
      `stop` or a second rebuild does not install its client.
14. **An agent's transcript is read from the agent's own file, never
    reconstructed from its terminal.** It goes through `MachineShell` (`/bin/sh`
    here, `ssh` to the tunnel's destination elsewhere) to the session herdr
    reported in `agent_session`.
    - `agent_session.value` came from a herdr server and goes into a shell
      script. An id must be `[A-Za-z0-9_-]`, a path an absolute `.jsonl` in
      single quotes; anything else gets no script at all.
    - An agent with no reader gets the screen only, not a guessed transcript.
      The screen is never removable: a waiting agent's prompt lives only there.
15. **`pane_updated` is not an agent-state signal;
    `pane.agent_status_changed` is.** `pane_updated` follows `revision`, which
    client rendering drives — with no client attached, a turn's return to
    `idle` pushes nothing. The status event needs a `pane_id`, so
    `MachineSession` keeps the watched set equal to its agent list and
    `LiveHerdrClient` reopens the subscription silently when it changes; a
    `pane_not_found` is treated as a drop and resyncs. While any agent is
    working, the supervisor tick compares `agent.list` stamps and resyncs on a
    difference, to cover the reopen gap.

## Decisions kept on record

- **`StateClassifier` does not defer to `agent.explain`**, and reads 12
  non-empty lines, matching herdr's own rule scope. Reasoning and measurements
  in [`docs/herdr-protocol.md`](docs/herdr-protocol.md#agentexplain-decision).

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
