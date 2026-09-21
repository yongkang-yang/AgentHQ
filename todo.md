# TODO

Working notes, not a roadmap — BD-104 holds the milestones. This file is where
the loose ends live so the next session does not have to rediscover them.

Last touched after milestone 7 (interventions) landed in the working tree.

## Done since this file was written

Milestone 7 (interventions) is committed, with tests. 116 tests green.

- **`PromptAffordances`** — 17 tests, pinned to prompt strings taken verbatim
  from herdr's own agent manifests in
  `~/.local/state/herdr/agent-detection/remote/*.toml`, which are the same
  literals herdr matches to decide a pane is blocked. The negative cases are
  assertions in their own right: a highlighted-row menu whose footer says
  "enter to confirm · esc to cancel" yields `approveKey == nil`, and so does
  every "enter to select / submit / toggle" footer.
- **The guard in `MachineSession.perform`** — 11 tests against a recording
  fake client, each asserting that a refusal sent *nothing*, not merely that
  an error came back. Required making `MachineSession` take `any HerdrClient`
  with an injectable factory; it took a concrete `LiveHerdrClient` before.
- **`AgentActions` per state** — covered in the affordances suite.
- **Invariant 7 corrected** in `AGENTS.md`, and independently re-measured
  first rather than taken on trust. It is now invariants 7–10, covering the
  `state_change_seq` / `revision` distinction, the `agent.prompt` → `target`
  finding, and the rule against provider-keyed answer tables.
- **`README.md`** milestone list is current.

Still not done from that list:

- **A live intervention test.** The guard is covered against a fake; nothing
  drives a real blocked agent end to end. `pane.report_agent` can fabricate a
  blocked agent on a throwaway pane without involving a real one, which is how
  the protocol findings above were measured.

## Then milestone 8

Machines UI and notification rules.

Two things found while building milestone 7 that belong to it:

- **Notification rules have a natural source of truth.** `agent.explain` returns
  herdr's own rule evaluation for a pane — rule id, priority, matched flag, and
  the evidence region it matched against. A notification that says *which rule*
  fired is far better than one that says "needs approval".
- **`server.agent_manifests` lists every agent herdr can detect** (21 of them,
  remotely updated). A machines UI can say what a host is capable of seeing.

## Open questions, not yet decided

- **Should `StateClassifier` defer to `agent.explain`?** herdr already
  classifies with per-agent manifests that are remotely updated, region-scoped,
  and maintained by someone else. Our hand-rolled regexes are the thing that
  reported a pane discussing "rateLimited" *as* rate limited. Leaning on
  `agent.explain` would likely be both more accurate and less code — but it is
  one round trip per pane, and it reports herdr's four states, so the mapping
  onto our nine still has to live somewhere. Worth measuring before choosing.
- **`approveKey` is nil for most agents**, because most prompts are
  highlighted-row menus. That is the honest answer, but it means the Approve
  button rarely appears, and a triage panel where the main action is usually
  missing may not be worth the row space. The alternative is an "Open pane"
  action that focuses the pane in herdr (`pane.focus` + `workspace.focus`),
  which is always truthful. Probably both.
- **Nudge has no confirmation.** Text typed into the panel goes straight to a
  live agent. Fine for "keep going", less fine for a typo sent to the wrong row.
