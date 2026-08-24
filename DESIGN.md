# Sigil design system

## Strategy

**Restrained.** A neutral black shell, one ember accent under 5% of the surface.
The accent comes off the app's own sigil mark and is reserved for state: a pinned
row, a session doing work, the current folder, a focused field. It is never
decoration. The conversation on screen is marked by the `selected` fill, not by
an accent stripe.

The window is one surface. Every chrome colour is derived from the terminal theme,
with the hue removed from the panel greys, so a tinted terminal can never leak
colour into the shell.

## Colour

Dark ramp (Grok Night), in the order they stack:

| Role       | Value     | Used for                                    |
|------------|-----------|---------------------------------------------|
| `sidebar`  | `#000000` | The rail. True black, and the darkest surface.|
| `ground`   | `#0A0A0A` | Window and terminal, sitting above the rail.|
| `raised`   | `#1A1A1A` | Hover, search field, selected tab.          |
| `selected` | `#262626` | The row whose conversation is on screen.    |
| `hairline` | `#2B2B2B` | Every border and every row rule.            |
| `text`     | `#EDEDED` | Titles, active labels.                      |
| `textDim`  | `#9A9A9A` | Inactive labels, secondary controls.        |
| `textFaint`| `#6B6B6B` | Metadata, section headers, counts.          |
| `accent`   | `#E8934A` | Active conversation, working dot, focus ring.|

Text steps are discrete values, not opacities of one colour. Opacity ramps mush
together over a near-black ground and are the reason grey-on-black reads unfinished.

## Type

Two families on a contrast axis:

- **SF (system)** for anything a human wrote: conversation titles, labels, buttons.
- **SF Mono** for anything a machine wrote: folder slugs, timestamps, counts,
  paths. This is what makes metadata read as metadata rather than as a failed title.
  Section titles stay in SF, because they are labels a human reads as structure.

Fixed scale, no fluid sizing. 12 / 11.5 / 10 / 9.5 px. Product UI is viewed at one
DPI; clamped headings serve nothing here.

## Density

The list is the product, and it is read at a glance, not scanned for maximum count.
A row is two lines — title, then folder and time in mono — with 8pt above and below
and a rounded hover/selected fill. About 44pt in total.

Hairlines between every row were the previous separator. They made a 600-thread
list look like a table. Frontier chat lists separate rows with fill, not rules.
Two-line rows stay: a single line was tried and the titles ran together.

Section headers for Recents are uppercase with a count, `PINNED (2)` / `TODAY (1)`,
because that is how the chosen mockup marks structure. They take 16pt above and
5pt below. Project names stay in their own case, `sigil (4)`, so a folder slug
does not become a shout.

The sidebar has one list and two sorts. Recents is time. Projects is the same
chats grouped by working folder. Pins sit at the top of either sort.

## Type ramp and the contrast floor

`textDim` and `textFaint` are floored by WCAG AA against the *selected* row, not
chosen by eye. Below that floor, hierarchy is carried by size and by the switch to
mono — never by more grey.

## State vocabulary

Every interactive element ships all of these, or it is not done:

- **Row**: default, hover (`raised` fill), open, active (`selected` fill + medium title). Titles stay at `text`; metadata carries the dim. No side stripe.
- **Pin**: hover control on the trailing edge; a small ember pin stays on pinned rows.
- **Field**: default, hover, focused (ember hairline).
- **Icon button**: default, hover, on.
- **Session**: starting, working (pulsing ember on the row), idle, exited.
- **Folder**: in Projects sort, the working folder is a section of chats, not a
  drill-in. The current folder is the one you are already in; it does not need
  a second icon language.

## Motion

150–200ms, ease-out. Motion reports state changes only: the sidebar collapsing, a
session starting work. There is no page-load choreography — the app opens into a
task.
