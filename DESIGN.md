# Sigil design system

## Strategy

**Restrained.** A neutral black shell, one ember accent under 5% of the surface.
The accent comes off the app's own sigil mark and is reserved for state: the active
conversation, a session doing work, a focused field. It is never decoration.

The window is one surface. Every chrome colour is derived from the terminal theme,
with the hue removed from the panel greys, so a tinted terminal can never leak
colour into the shell.

## Colour

Dark ramp (Grok Night), in the order they stack:

| Role       | Value     | Used for                                    |
|------------|-----------|---------------------------------------------|
| `ground`   | `#0A0A0A` | Window and terminal. The floor.             |
| `sidebar`  | `#0E0E0E` | The thread viewer panel.                    |
| `raised`   | `#1A1A1A` | Hover, search field, selected tab.          |
| `selected` | `#232323` | The row whose conversation is on screen.    |
| `hairline` | `#282828` | Every border in the app. There are no others.|
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
  section headers, paths. This is what makes metadata read as metadata rather than
  as a failed title.

Fixed scale, no fluid sizing. 12 / 11.5 / 10 / 9.5 px. Product UI is viewed at one
DPI; clamped headings serve nothing here.

## Density

The list is the product. **A row is one line.** Title on the left, a compact
relative time on the right, 26pt tall. Two lines per row was tried and failed: the
folder slug is near-identical between neighbouring rows, so a second line made every
row look like every other one. What distinguishes a conversation is its title, and
the title gets every point the time does not. The folder lives in the tooltip and in
the folder filter.

Section headers cost 20pt. Nothing in the chrome is allowed to grow at the list's
expense.

## Type ramp and the contrast floor

`textDim` and `textFaint` are floored by WCAG AA against the *selected* row, not
chosen by eye. Below that floor, hierarchy is carried by size and by the switch to
mono — never by more grey.

## State vocabulary

Every interactive element ships all of these, or it is not done:

- **Row**: default, hover, open (dim ember bar), active (ember bar + `selected` fill).
- **Field**: default, hover, focused (ember hairline).
- **Icon button**: default, hover, on.
- **Session**: starting, working (pulsing ember), idle, exited.

## Motion

150–200ms, ease-out. Motion reports state changes only: the sidebar collapsing, a
session starting work. There is no page-load choreography — the app opens into a
task.
