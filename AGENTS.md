# Repository Guidelines

## Project structure

Swift 6 package, macOS 14+. Five targets, layered so that each one depends only
on the ones above it:

- `Sources/AgentHQKit/` — domain model. **No I/O.** If a type here needs a
  socket, a file, or a clock it cannot control, it belongs in another target.
- `Sources/AgentHQTransport/` — `LocalSocketTransport` and `SSHTunnel`. Both
  resolve to a local unix socket path.
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
5. **Two sockets to herdr, not one.** Request/response and the event stream get
   separate connections. Sharing one races two readers on the same fd and
   corrupts NDJSON framing.
6. **No continuous animation inside `MenuBarExtra`.** It causes the panel to
   flicker open and closed. Emphasis is static.

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
