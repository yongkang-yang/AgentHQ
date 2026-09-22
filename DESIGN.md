---
name: AgentHQ
description: A calm macOS menu-bar control plane for AI coding agents across every machine you work on
colors:
  accent: "#8A5A00"
  accent-deep: "#6B4500"
  crashed: "#B3261E"
  needs-you: "#8A5A00"
  failed: "#9A3412"
  rate-limited: "#00625E"
  finished: "#1E4BD2"
  working: "#1A3A69"
  unknown: "#5F666B"
  machine-down: "#C2410C"
  secondary-text: "#5A5F64"
  approve-fill: "#1A3A69"
typography:
  display:
    fontFamily: "SF Pro Rounded"
    fontSize: "22px"
    fontWeight: 700
  title:
    fontFamily: "SF Pro"
    fontSize: "15px"
    fontWeight: 700
  body:
    fontFamily: "SF Pro"
    fontSize: "12.5px"
    fontWeight: 500
  label:
    fontFamily: "SF Pro"
    fontSize: "10.5px"
    fontWeight: 600
  mono:
    fontFamily: "SF Mono"
    fontSize: "10.5px"
    fontWeight: 500
rounded:
  card: "10px"
  field: "7px"
  pill: "999px"
spacing:
  gutter: "14px"
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "10px"
  xl: "12px"
---

# Design System: AgentHQ

> Ported and adapted from Shepherd's design system (MIT, © Shyam Pandya).
> See NOTICE. The token layer, the AA floor, the one-color-per-state idea, and
> the no-animation rule are Shepherd's; the machine dimension and the nine-state
> vocabulary are AgentHQ's.

## Overview

**Creative north star: "One calm control plane."**

AgentHQ watches agents on machines the user cannot see. That is the whole
design problem: the panel is the only evidence that a build box three hops away
is doing anything at all, so it has to be believable before it is beautiful. The
language is a quiet native macOS utility — one warm accent, a small vocabulary
of status lights, and a hard rule that nothing is ever shown with more certainty
than it is known.

Density is deliberate. Rows are compact, the panel is a fixed 500pt, and every
line earns its place. The voice is domain-native and honest: exact dwell
figures, "Needs you" rather than marketing, and "unreachable — ssh exited"
rather than a spinner.

**Key characteristics:**

- One warm amber accent; status colors are information, not decoration
- Calm static emphasis — no continuous animation anywhere
- WCAG AA (≥4.5:1) for every text color in both appearances, verified
- Native macOS materials, controls, and SF Symbols throughout
- Machine is on every row; unreachability has its own language

## Colors

Two layers: an adaptive body layer that resolves per appearance, and a fixed
menu-bar layer that uses system colors because the badge is baked into an
`NSImage` at paint time and would otherwise resolve against the wrong
appearance.

### Accent

- **Warm Amber** `#8A5A00` light / `#FFC94D` dark — the single accent:
  selection strokes, the mark, emphasis. Never a flat decorative pour.

### Status lights

Nine states, seven colors. Color narrows the *category*; the pill label names
the state. This is a deliberate departure from Shepherd's one-color-per-state
rule, which does not survive nine states — past about six, added hues stop
being distinguishable at 8pt and the user starts reading the text anyway. Better
to make the text load-bearing on purpose than to ship four warm reds and pretend
they are distinct.

| Color | Light | Dark | States |
| --- | --- | --- | --- |
| Alarm Red | `#B3261E` | `#FF6B6B` | `crashed` |
| Needs-You Amber | `#8A5A00` | `#FFC94D` | `needsApproval`, `needsInput` |
| Failure Orange | `#9A3412` | `#F59E5B` | `ciFailed`, `mergeConflict` |
| Waiting Teal | `#00625E` | `#5ED4CE` | `rateLimited` |
| Done Blue | `#1E4BD2` | `#6CA6FF` | `finished` |
| Working Navy | `#1A3A69` | `#8BADDC` | `working` |
| Unknown Grey | `#5F666B` | `#929A9F` | `unknown` |

Measured contrast on `#FFFFFF` / `#1E1E1E`: 6.54/6.01, 5.93/10.89, 7.31/7.88,
7.22/9.36, 7.02/6.78, 11.33/7.23, 5.83/5.83. All clear the 4.5:1 floor.

Waiting Teal is the one cool color in the attention group, and that is the
point: `rateLimited` is the only attention state the user cannot clear by
acting. It needs to read as "stalled", not as "do something".

### Operational

- **Machine Down Orange** `#C2410C` / `#FFA726` — a machine AgentHQ cannot
  reach. Reserved for machine-level trouble; never used for an agent.
- **Secondary Text** `#5A5F64` / `#B3B8BD` — the one grey vocabulary. Replaces
  system `.secondary`/`.tertiary`, which fall to ~3.5:1 and ~2.2:1 on small
  light-mode text.
- **Approve Fill** `#1A3A69` / `#102445` — affirmative button fill, dark enough
  that white label text holds AA in both appearances.

### Named rules

**The One Accent Rule.** Amber is the single accent, used sparingly. Status
colors carry information; they are not decoration.

**The AA Floor Rule.** Every text color holds ≥4.5:1 in both appearances,
measured rather than assumed. Pill text uses a strengthened variant because the
tinted fill pulls the background toward the text color. If a shade cannot hold
the floor, darken the light variant and brighten the dark one — never ship a
grey.

**The Fixed Badge Rule.** The menu-bar label is the app icon plus a single
state glyph and its count. One indicator, chosen by severity — needs-input
before finished before working before idle — never one indicator per state:
the bar has room for one number, and a blocked agent must not be hidden behind
the working ones. State is carried by the glyph's shape and the number, not by
colour, so the bar stays legible on light, dark, and wallpaper-tinted bars
alike.

**The Separate Axis Rule.** Machine trouble never borrows an agent color.
A machine going dark is rendered in Machine Down Orange at the machine level,
and its agents go stale — dimmed and un-actionable — rather than turning red.
One dropped tunnel must never look like twelve dead agents.

## Typography

Pure system type — SF Pro, SF Pro Rounded for display moments, SF Mono for
anything measured. Personality comes from weight and role, not from a custom
face.

- **Display** (700, 22pt) — the one big number. Rounded.
- **Title** (700, 15pt) — panel title.
- **Body** (500, 12.5pt) — reasons, action summaries. 13.5pt semibold for the
  agent name line.
- **Label** (600, 10.5pt, 0.4pt tracking) — pills (uppercased), buttons.
- **Section header** (600, 11.5pt) — sentence case with a mono count, as
  macOS 26 menus head their sections.
- **Mono** (500, 10.5pt) — dwell, machine names, paths, params.

**The Measured-Data Rule.** Anything measured is monospaced: dwell durations,
paths, params. **The machine name is monospaced too** — it is an address, and
addresses are read character by character.

## Layout

A fixed 500pt-wide menu-bar window, content-driven height. Header, filter bar,
three agent sections, machine-status strip, footer. The agent list is the only
flexible piece; it carries a measured height capped around 540pt so a short
list shrinks the panel and a long one scrolls.

Spacing rhythm: 14pt gutter, 10pt row padding, 4pt line spacing, 9–12pt section
separation.

### The machine dimension

The fleet adds a second axis to a layout that previously had one. The rule is
**group by attention, label by machine** — not the reverse. A user with a
blocked agent needs to find it regardless of which box it is on; forcing them
to scan three machine sections to find the one red row inverts the product.

So: machine appears as a monospaced chip on every row, is available as a
filter, and gets its own status strip at the bottom of the panel for
machine-level trouble. It is never the primary grouping.

## Elevation and depth

Flat by design. No drop shadows, no card floats. Depth comes from tonal
layering — `Color.primary.opacity()` fills at 0.025 resting, 0.05–0.06 hover,
0.14 pill fills — over a `regularMaterial` background.

The one sanctioned glow is the status rail and dot: a soft colored halo that
brightens when an agent is working or alarmed. It is a *response to state*, not
ambient furniture.

## Components

- **Agent row** — 12pt continuous corner (concentric with the popover at the
  14pt gutter), 3.5% primary fill (6% hover), 1pt
  accent-tinted hairline. Left status rail, 3.5pt capsule in the state color.
  Stale rows (machine not connected) drop to 50% opacity and lose their
  actions — visible, clearly not current, not clickable.
- **State pill** — capsule, uppercased 10.5pt semibold, solid state colour
  with white text (near-black in dark mode, where the state colours are too
  light to carry white). The one filled chip on a row.
- **Machine chip** — monospaced 10.5pt, primary text on a 20% wash of a
  per-machine colour with a 0.5pt hairline at 45%. Machines are an identity
  axis, so the colour is stable per machine id, not the state palette and not
  a status signal. It is a wash where the state pill is solid, which is what
  keeps "which box" from reading as "what state" — and keeps the machine,
  which is context, quieter than the state, which is the news. Machine trouble still overrides
  nothing here — it is the status strip and dot that turn Machine Down Orange.
- **Machine strip** — folded by default to one line: a reachability dot per
  machine, the count, and the name of any machine not simply connected
  ("build-box unreachable"), in Machine Down Orange when one is down. Unfolds
  to a row per machine with the reason verbatim. Folding never hides trouble.
- **Menu bar indicator** — the robot mark, then the most urgent state and its
  count. A state that wants the user (Needs you, finished) is a solid capsule
  with the glyph and count knocked out; working is the same glyph and count,
  bare. The difference is in silhouette because a template image has no
  colour, and an 8.5pt glyph's interior is not a difference anyone can see.
- **Buttons** — Liquid Glass capsules on macOS 26+, small control size, one
  `GlassEffectContainer` per action row. Committing actions (Approve, Send,
  Confirm) are prominent glass in a fixed blue that holds white text in both
  appearances; End's confirmation is prominent in Alarm red; everything else is
  clear glass with the tint on the label — End red (`#B91C1C` / `#F87171`),
  Continue and Nudge green (`#15803D` / `#4ADE80`), Reveal orange
  (`#C2410C` / `#FB923C`), each its own token. Before macOS 26, a 14% tinted
  capsule wash.

## Liquid Glass

Glass is the control layer, never the content. The popover is glass on
macOS 26, so rows, pills and chips stay tonal fills on it — glass on glass
reads as noise, and a glass card reads as a button. Only what the user presses
floats. Separators are inset; the list's scroll edges soften under a `.soft`
scroll-edge effect instead of a hard rule. Toggles are mini switches.

## Do's and don'ts

**Do**

- Use the token layer for every color — never raw hex in views. The tokens
  encode the AA floor and both appearances.
- Keep the status vocabulary consistent across menu bar, rail, dot, and pill.
- Put the machine on every row, in mono.
- Show degraded as degraded, with the reason, verbatim.
- Use system materials, controls, and SF Symbols. This is a native utility.

**Don't**

- Don't ship system `.green`, `.orange`, `.secondary`, or `.tertiary` for text
  — they fail AA in light mode.
- Don't add continuous animation inside the menu-bar panel. It is a known
  cause of the panel flickering open and closed.
- Don't group the panel by machine. Group by attention.
- Don't render a stale agent as a current one, and never as a crashed one.
- Don't invent new greys. One secondary-text token, one vocabulary.
- Don't add a color for a new state before checking whether an existing
  category already covers it. Seven is already near the limit.
