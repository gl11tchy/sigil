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
  section headers, paths. This is what makes metadata read as metadata rather than
  as a failed title.

Fixed scale, no fluid sizing. 12 / 11.5 / 10 / 9.5 px. Product UI is viewed at one
DPI; clamped headings serve nothing here.

## Density

The list is the product, and it is read at a glance, not scanned for maximum count.
A row is two lines — title, then folder and time in mono — with 10pt above and below
and a hairline rule between rows. About 50pt in total.

Packing more rows in was tried twice and failed both times. Rows at 32pt with no rule
read as one continuous block of text; collapsing to a single line made that worse,
not better, because the eye had nothing to break on. **The rule between rows is what
separates them, not tightness.** Vertical room is cheap here: the user is looking for
one conversation they half-remember, not counting how many fit on screen.

Section headers take 16pt above and 6pt below, because they separate days and that
break should be the largest one in the list.

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
