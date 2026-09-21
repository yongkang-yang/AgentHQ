# AgentHQ

A native macOS menu-bar app for seeing AI coding agents running across every
machine you work on — this Mac, remote Linux/macOS hosts over SSH, and Windows
machines through WSL — in one place.

It answers three questions at a glance:

1. What agents are running?
2. Which ones need me?
3. What is the next action?

AgentHQ is **attention-first**, not a process list. Agents that are blocked,
waiting for approval, failed, rate-limited, or finished come first; working
agents stay visible but secondary.

Status: **early.** The domain model, transport, herdr client, and fleet
session are in place and verified against a live herdr. The menu bar renders
a real herd from the local machine. Remote machines work as far as the tunnel
— see [Milestones](#milestones).

`ssh -L` unix-socket forwarding is verified against a WSL2 host over
Tailscale: usable 0.3s after launch, two concurrent connections served
independently, a 200KB round trip in ~98ms.

## How it works

```
AgentHQ.app
│
├── Local machine
│   └── herdr
│
├── Remote macOS / Linux
│   └── SSH → herdr
│
└── Windows machine
    └── SSH → WSL → herdr
```

AgentHQ uses [herdr](https://herdr.dev) as its runtime layer for agent
discovery, state, and pane output. A remote machine is reached by forwarding
its herdr socket with `ssh -N -L <local.sock>:<remote.sock>`, which means a
remote machine reduces to *a different socket path on this Mac*. Nothing above
the transport layer knows the difference.

WSL is treated as an ordinary Linux host running its own sshd — not as
something reached through Windows.

## Architecture

```
AgentHQKit        domain model, zero I/O
AgentHQTransport  LocalSocket | SSHTunnel — both resolve to a local socket path
AgentHQHerdr      herdr wire protocol; knows one path, nothing about fleets
AgentHQFleet      MachineSession × N, and the snapshot assembled from them
AgentHQApp        SwiftUI menu bar
```

The layering is enforced by the package graph, and the direction of ignorance
is the point: `AgentHQHerdr` cannot accidentally learn about machines, so all
multi-machine complexity stays in `AgentHQFleet`.

Two invariants worth knowing before reading the code:

- **A pane id is only meaningful inside one machine.** herdr numbers panes per
  host and has no idea other hosts exist, so `AgentRef` (machine + pane) is the
  key for anything fleet-wide. `AgentID` alone goes back on the wire verbatim.
- **Machine reachability is a separate axis from agent state.** When SSH drops,
  the agents on the far side are fine — AgentHQ just stopped seeing them.
  Collapsing that into a per-agent "crashed" turns one dropped tunnel into
  twelve false alarms.

## Requirements

- macOS 14+
- Swift 6 toolchain (Xcode 16+)
- [herdr](https://herdr.dev) on every machine you want to watch
  (verified against herdr 0.9.0, wire protocol 22)
- OpenSSH 6.7+ for remote machines (unix-socket forwarding)

## Build

```sh
swift build
swift test
swift run AgentHQApp
```

## Milestones

1. ~~Skeleton — layering, domain model, transport design~~ ✅
2. **Remote walking skeleton** — in progress. SSH tunnel supervision, the
   herdr client, and the fleet session are done and verified end to end
   against a local herdr; the remote leg needs herdr installed on a second
   machine.
3. ~~Local machine as the degenerate case (transport = local)~~ ✅ — it fell
   out of the transport design for free
4. Normalized state classifier + attention triage
5. Interventions — approve/deny, nudge, interrupt/stop
6. Machines settings UI, notification rules

Not in v1: usage/cost dashboard, MCP server, detecting agents outside herdr,
a terminal emulator.

## License

GPL-3.0 — see [LICENSE](LICENSE).

Parts of AgentHQ are ported from
[Shepherd / herdr-manager](https://github.com/sxp4931/herdr-manager) (MIT,
© Shyam Pandya). See [NOTICE](NOTICE) for what was ported and the MIT terms
that continue to apply to it.
