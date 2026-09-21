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

- **A live intervention test** — done. Drives a fabricated blocked agent over
  the real socket and asserts the keystroke lands in the pane, and that a
  refused one leaves it byte-identical. It caught a real disagreement on its
  first run: `PromptAffordances` found cursor's `(y)` while `StateClassifier`
  matched none of its phrase rules, so the row said "needs input" and offered
  an Approve button. The classifier now consults the affordances.

## Milestone 8 — done

**Notification rules.** The decisions live in `NotificationPolicy` in
`AgentHQKit`, pure except for the memory of what it has already said, which is
what makes them testable without a notification centre. The rules that matter:

- The first snapshot only teaches. At launch every agent is new, and a herd
  that has been sitting blocked for an hour is not news.
- Announce on *entering* a state, never on every refresh.
- `finished` is not announced. It is good news that can wait, and one
  notification per completion is most of the noise a fleet produces.
- `rateLimited` is announced although the user cannot clear it — otherwise
  they assume progress.
- A batch is one notification. Five at once is one event to a human.
- Agents on an unreachable machine announce nothing; the machine announces
  itself, once. A dropped tunnel must not read as a burst of alarms.
- Every announcement names its machine.

**Machines UI.** The footer rows became actionable: enable/disable without
forgetting the machine, retry rather than waiting out a reconnect cycle, and
the herdr version each host is running — hosts drift, and an old one reports
fields this client no longer reads. The failure reason is shown verbatim.

Not done, and deliberately: `server.agent_manifests` lists the 21 agents herdr
can detect. Interesting, but it answers a question nobody has while triaging.

## Decided: `StateClassifier` does not defer to `agent.explain`

Measured rather than argued, against herdr 0.9.0, by fabricating each case in a
throwaway pane and asking `agent.explain`:

| pane shows | herdr's state | its matched rule |
| --- | --- | --- |
| cursor's approval prompt | `blocked` | `approval_prompt` |
| an open question | `idle` | none |
| a merge conflict | `idle` | none |
| a 429 and a retry-after | `idle` | none |

herdr models none of the three states that are ours — conflict, failed run,
rate limit all come back `idle`, because it has no rules for them. So explain
could never replace the classifier; at most it could second-opinion the
blocked/approval half.

And that half is already better served. herdr's rule-derived state arrives free
in `agent_status` on every snapshot, so explain's only marginal contribution is
the rule id. Meanwhile approval is now decided by whether the prompt names a key
to say yes with, which is strictly more useful than a boolean: it also says
*which key*, which is what the button has to send. Adding explain would cost one
more round trip per stopped pane — ~115ms each across a tunnel — to learn less
than we already have.

Kept as the upgrade path if approval detection turns out wrong in practice:
`explain.matched_rule` is maintained by someone else, remotely updated, and
scoped per agent.

**What the measurement did change:** herdr scopes its rules to
`bottom_non_empty_lines(n)`, most often 8 and at most 20. The classifier was
reading 40 *raw* lines — wider than any of herdr's, in the wrong unit, and
inconsistent with `PromptAffordances`, which already counted 14 non-empty.
Width was the failure that actually bit, when prose further up mentioning
"rateLimited" was read as a rate limit. Now 12 non-empty, with a test asserting
it cannot drift past herdr's own widest.

## Open questions, not yet decided

- **`approveKey` is nil for most agents**, because most prompts are
  highlighted-row menus. That is the honest answer, but it means the Approve
  button rarely appears, and a triage panel where the main action is usually
  missing may not be worth the row space. The alternative is an "Open pane"
  action that focuses the pane in herdr (`pane.focus` + `workspace.focus`),
  which is always truthful. Probably both.
- **Nudge has no confirmation.** Text typed into the panel goes straight to a
  live agent. Fine for "keep going", less fine for a typo sent to the wrong row.
