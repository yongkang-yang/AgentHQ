---
name: AgentHQ
description: A calm macOS menu-bar control plane for AI coding agents across every machine you work on
colors:
  needs-you: "#8A5A00"
  broken: "#C62828"
  stalled: "#6D28D9"
  working: "#1D4ED8"
  finished: "#137333"
  quiet: "#5F666B"
  secondary-text: "#5A5F64"
  prominent-fill: "#242424"
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
language is a quiet native macOS utility — neutral chrome, a small vocabulary
of status lights that are the only colour on screen, and a hard rule that nothing is ever shown with more certainty
than it is known.

Density is deliberate. Rows are compact, the panel is a fixed 500pt, and every
line earns its place. The voice is domain-native and honest: exact dwell
figures, "Needs you" rather than marketing, and "unreachable — ssh exited"
rather than a spinner.

**Key characteristics:**

- Colour means state and nothing else; every control and chip is neutral
- Calm static emphasis — no continuous animation anywhere
- WCAG AA (≥4.5:1) for every text color in both appearances, verified
- Native macOS materials, controls, and SF Symbols throughout
- Machine is on every row; unreachability has its own language

## Colors

Two layers: an adaptive body layer that resolves per appearance, and a fixed
menu-bar layer that uses system colors because the badge is baked into an
`NSImage` at paint time and would otherwise resolve against the wrong
appearance.

### Status lights

Six hues, grouped by what the user does next, and they are the **only**
saturated colours in the app. The pill label names the exact state; the colour
says which kind of attention it wants.

| Group | Light | Dark | States |
| --- | --- | --- | --- |
| Needs-you Amber | `#8A5A00` | `#FBBF24` | `needsApproval`, `needsInput` |
| Broken Red | `#C62828` | `#FF7B72` | `crashed`, `ciFailed`, `mergeConflict` |
| Stalled Violet | `#6D28D9` | `#B69CFF` | `rateLimited` |
| Working Blue | `#1D4ED8` | `#6AA8FF` | `working` |
| Finished Green | `#137333` | `#4ADE80` | `finished` |
| Quiet Grey | `#5F666B` | `#9BA3A8` | `idle`, `unknown` |

Every pair holds ≥4.5:1 as text on both panel surfaces of its appearance
(`#FFFFFF`/`#F0F0F0`, `#1E1E1E`/`#2C2C2C`), and as a pill fill under its label
(white in light mode, `#111315` in dark). Group representatives are at least
30° apart in hue in each appearance. `PaletteTests` enforces all three.

Why these groups. Working was navy and finished was blue — 11° apart, one
colour at a glance. Crashed, failure and machine-down were three neighbouring
warm reds and oranges beside a needs-you amber. Crashed, tests failed and merge
conflict now share Broken Red, told apart by glyph and pill word: all three
mean "something went wrong, go look". Stalled Violet is the one attention state
the user cannot clear by acting, so it is the one that is neither warm nor
calm.

### Neutrals

- **Secondary Text** `#5A5F64` / `#B3B8BD` — the one grey vocabulary. Replaces
  system `.secondary`/`.tertiary`, which fall to ~3.5:1 and ~2.2:1 on small
  light-mode text.
- **Action text** — primary label colour. Every button label.
- **Prominent Fill** `#242424` / `#E8E8E8` — the committing button (Approve,
  End it, New output), an inverted neutral with its label the other way round.
  It stands out by weight, not hue.
- **Chip wash** — 7% primary with a 14% hairline. Machine chips and the
  machine bar.
- **Problem** — primary text behind `exclamationmark.triangle.fill`. A machine
  that cannot be reached, a refused click, a herdr error.

### Named rules

**The Colour Is State Rule.** A saturated colour on screen always means an
agent state. Buttons, chips, links, errors and machine trouble are neutral —
system link blue included, since it is working's blue. A coloured End or Reveal
reads as a second state beside the real one.

**The AA Floor Rule.** Every text color holds ≥4.5:1 in both appearances,
measured rather than assumed. If a shade cannot hold the floor, darken the
light variant and brighten the dark one — never ship a grey.

**The Fixed Badge Rule.** The menu-bar label is the app icon plus a single
state glyph and its count. One indicator, chosen by severity — needs-input
before finished before working before idle — never one indicator per state:
the bar has room for one number, and a blocked agent must not be hidden behind
the working ones. State is carried by the glyph's shape and the number, not by
colour, so the bar stays legible on light, dark, and wallpaper-tinted bars
alike.

**The Separate Axis Rule.** Machine trouble never borrows an agent color.
A machine going dark is shown at the machine level in primary text behind a
warning glyph, and its agents go stale — dimmed and un-actionable — rather
than turning red. One dropped tunnel must never look like twelve dead agents.

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

- **Panel** — a borderless window under the status item, 28pt continuous
  corner, no arrow, as Tahoe's own menu-bar panels. Not an `NSPopover`, whose
  corner cannot be changed. The surface is the system popover material (about
  237 over a white page), not Liquid Glass: glass rendered pure white there
  and the panel lost its edge. No shadow — the window server's traced one
  squared off the bottom corners, and a drawn one read as haze — so the edge
  is the material's tone plus a 0.5pt hairline at 14% black (18% white in
  dark mode). Liquid Glass is on the controls only.
- **Agent row** — 14pt continuous corner (concentric with the panel's 28pt at
  the 14pt gutter), 3.5% primary fill (6% hover). Left status rail, 3.5pt capsule in the state color.
  Stale rows (machine not connected) drop to 50% opacity and lose their
  actions — visible, clearly not current, not clickable.
- **State pill** — capsule, uppercased 10.5pt semibold, solid state colour
  with white text (near-black in dark mode, where the state colours are too
  light to carry white). The one filled chip on a row.
- **Machine chip** — monospaced 10.5pt, primary text on the neutral chip
  wash. It was a hue per machine, and a red "wsl" chip beside a red "crashed"
  pill read as a second alarm. Machines are told apart by name here and by
  glyph in the machine bar.
- **Machine bar** — a glyph, short name and agent count per machine, on the
  chip wash. A machine not simply connected spends that room on its state in
  a word ("WSL unreachable") and Retry; a down one adds the problem glyph.
  Folding never hides trouble.
- **Menu bar indicator** — the robot mark, then the most urgent state and its
  count. A state that wants the user (Needs you, finished) is a solid capsule
  with the glyph and count knocked out; working is the same glyph and count,
  bare. The difference is in silhouette because a template image has no
  colour, and an 8.5pt glyph's interior is not a difference anyone can see.
- **Buttons** — Liquid Glass capsules on macOS 26+, small control size, one
  `GlassEffectContainer` per action row. Every label is primary text on clear
  glass. The committing action (Approve, End it) is prominent glass in the
  inverted neutral. Before macOS 26, a chip-wash capsule, or the prominent fill.

## Liquid Glass

Glass is the control layer, never the content. The panel is the system
popover material, and rows, pills and chips stay tonal fills on it — a glass
card reads as a button. Only what the user presses floats. Separators are inset; the list's scroll edges soften under a `.soft`
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
  group already covers it. Six is the budget.
- Don't colour a button, a chip, a link or an error. Colour is state.
