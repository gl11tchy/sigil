# Sigil design system

Sigil is built on the principles of [Beautiful UI](https://www.beautifului.dev/)
and on nothing else. Every surface — the Mac app, the website, and the phone
companion — uses the same tokens, the same two typefaces, the same radii, and
the same motion. When this file and Beautiful UI disagree, Beautiful UI wins and
this file is wrong.

## Principles

1. **Quiet chrome, loud content.** Cool near-neutral greys carry the window.
   Colour appears only where it carries state.
2. **One token set, two appearances.** Every colour is a named token with a
   dark and a light value. Views name tokens, never hex.
3. **Structure from fill and ring, not from lines.** A hover is a fill. A card
   is a fill with a 1px ring. Rules separate regions, never rows.
4. **Machine text is mono.** Anything a program wrote — paths, times, counts,
   shortcuts, code — is JetBrains Mono. Anything a person reads as language is
   Inter.
5. **Motion reports state and glides.** Short ease-out transitions. A hover
   highlight slides between rows instead of blinking. No choreography.

## Tokens

Values are Beautiful UI's, written in OKLCH at the source and stored as sRGB
hex in `Palette.swift`, `Site/public/style.css`, and `Sidereal/public/style.css`.

| Token        | Dark       | Light      | Used for                                         |
|--------------|------------|------------|--------------------------------------------------|
| `page`       | `#17181A`  | `#FAFAFB`  | The window, the sidebar, the page behind cards.  |
| `canvas`     | `#1C1D1F`  | `#F1F2F3`  | The inset screen that holds tabs and the terminal.|
| `surface`    | `#232427`  | `#FFFFFF`  | Cards, popovers, sheets, the selected segment.   |
| `inset`      | `#1F2022`  | `#F7F8F9`  | Wells inside a card: a segmented track, a code block.|
| `hover`      | `#2A2B2E`  | `#F4F5F6`  | Pointer or keyboard over a row or control.       |
| `hover2`     | `#313236`  | `#E7E9EB`  | Selected: the open row, the selected tab, a secondary button.|
| `field`      | `#2B2C2F`  | `#F2F2F3`  | Text fields and the search box.                  |
| `lineSoft`   | `#27282B`  | `#F3F4F5`  | Rules inside a card.                              |
| `line`       | `#2E3033`  | `#ECEDEF`  | Region rules and card rings in light mode.       |
| `lineStrong` | `#3A3C40`  | `#E0E2E5`  | Key caps, focused-but-idle strokes.               |
| `ink`        | `#F2F3F4`  | `#1F2124`  | Titles, labels, body text.                        |
| `ink2`       | `#A5A8AD`  | `#62656B`  | Secondary text, metadata, placeholders.           |
| `ink3`       | `#787B81`* | `#83868B`* | Icons at rest, quiet marks. **Never words.**      |
| `accent`     | `#3D9AFF`  | `#0285FF`  | Primary button, focus ring, working mark, selection.|
| `accentInk`  | `#7EC0FF`  | `#0066D2`* | Accent-coloured text: links, search matches.      |
| `accentFill` | `#006FD0`* | `#006AE2`* | The fill behind white text: primary buttons, send.|
| `accentTint` | accent 16% | `#E9F3FF`  | Tinted fills: a selected list item, text selection.|
| `green`      | `#3CBB72`  | `#199A4D`  | Completed, connected.                             |
| `orange`     | `#F68F3C`  | `#EF720D`  | Waiting, warnings.                                |
| `red`        | `#EE5C61`  | `#E3474C`  | Failed, destructive.                              |
| tints        | colour 14% | solid tint | Status pill fills.                                |
| `tooltip`    | `#111214`  | `#25272B`  | Tooltip and toast ground.                         |

\* **The contrast floor.** Beautiful UI's `ink3` (`#6C6F75` / `#9A9DA3`) falls
under 3:1 on its own selected fills, so Sigil lifts it along OKLCH lightness to
3:1 on every panel — enough for an icon, never enough for words. Words use `ink` or `ink2`, which clear WCAG AA (4.5:1) on every
panel, including `hover2`. Text-only variants (`accentInk`, and `redInk`,
`greenInk`, `orangeInk` for status words) are moved along OKLCH lightness only
— hue kept — until they clear 4.5:1 on the hardest panel they sit on.
`accentFill` is the same move for the fill under white text, because white on
`accent` is under 3:1. `PaletteTests` holds the floor.

### Shadows and rings

A card is a fill plus a ring. In dark mode the ring is white at 11%; in light
mode it is `line`. Elevation adds a short, soft shadow under the ring:

| Name       | Dark                                          | Light                        |
|------------|-----------------------------------------------|------------------------------|
| `card`     | ring 11% + `0 1px 2px /20%` + `0 2px 6px /20%` | ring `line` + soft 6-layer   |
| `raised`   | ring 13% + `0 2px 10px /22%`                  | ring `line` + medium          |
| `overlay`  | ring 15% + `0 8px 28px /34%`                  | ring `line` + large           |
| `button`   | ring 10% + `0 1px 2px /30%`                   | ring `lineStrong` + 4px /4%   |

Never a 1px border plus a wide blur on the same element for decoration; the
ring *is* the border.

## Type

- **Inter** for every human-language string. Weights 400, 500, 600 only.
- **JetBrains Mono** for machine text, and for the terminal itself.
- Both are bundled (SIL OFL 1.1). The Mac app registers them at launch; the web
  surfaces self-host WOFF2. System fonts are the fallback, never the design.

Fixed scale, no fluid sizes. Product UI is read at one DPI.

| Step   | Size | Line | Used for                                       |
|--------|------|------|------------------------------------------------|
| title  | 15   | 20   | Sheet and page titles. 600.                     |
| body   | 13   | 18   | Rows, tabs, buttons, fields. 400; 500 when selected.|
| small  | 12   | 16   | Section labels, secondary lines.                 |
| mono   | 11.5 | 16   | Paths, times, counts in rows.                    |
| micro  | 10.5 | 14   | Key caps.                                        |

Tracking: `-0.01em` on 13 and up, `0` below. Sentence case everywhere: a
section is "Projects", never "PROJECTS". No tracked uppercase eyebrows.

Relative time is compact mono — `now`, `14m`, `3h`, `2d`, `3w`, then a short
date. Tooltips and accessibility labels spell it out.

## Shape

| Radius    | Value | Used for                                       |
|-----------|-------|------------------------------------------------|
| `chip`    | 6     | Tab chips, tool chips, key caps, status pills (small).|
| `control` | 8     | Rows, buttons, fields, icon buttons.            |
| `card`    | 10    | Cards, popovers, sheets, banners.               |
| `window`  | 14    | The canvas and the right panel.                 |
| pill      | full  | Segmented tracks, floating action bars, capsules.|

Spacing is a 4pt scale: 2, 4, 6, 8, 12, 16, 20, 24, 32.

## The window (Mac)

The window is `page`. The sidebar sits directly on it, with no border. The
working area is the **canvas**: a `window`-radius rectangle in `canvas`, inset
8pt from the top, right, and bottom edges, with the `card` ring. It holds, top
to bottom:

1. **Tab bar**, 40pt. Tab chips (28pt tall, `chip` radius, 13pt Inter). The
   selected tab is `hover2` with `ink`; others are `ink2` with a `hover` fill
   under the pointer. A plus follows the last chip. Folder breadcrumb (mono,
   `ink2`), panel toggle, and the session menu sit at the trailing edge.
2. A `line` rule.
3. **The terminal**, filling the rest, painted in the terminal theme's ground.
   The app's own themes (Sigil Dark, Sigil Light) paint it `canvas`, so the
   screen and its frame are one surface.

With the sidebar hidden, the canvas moves to the window's leading edge and
the tab bar reserves room for the traffic lights.

The **right panel** (⌥⌘B) is a second canvas beside the first, 8pt apart. Its
header is a segmented control — Shell, Notes — on an `inset` pill track, the
selected segment `surface` with the `button` ring.

Floating things inside the canvas are cards on `surface` with the `overlay`
shadow: the find bar (a pill, like Beautiful UI's selection actions), the tab
message (an approval card: question, text, Dismiss and Deliver), and the
ended-session capsule (a failed task row: red mark, reason, Restart, Close).

## The sidebar

Beautiful UI's sidebar nav, holding Sigil's lists.

- **Header row** beside the traffic lights: the collapse button at the
  trailing edge.
- **Search field**: `field` fill, `control` radius, 32pt, magnifier in `ink3`,
  placeholder "Search chats" in `ink2`, and a `⌘⇧F` key cap while empty.
  Focus draws a 1px `accent` ring.
- **Nav items**, 30pt, 16pt icon + label, trailing mono count or key cap:
  New session `⌘T`, Recents (count), Archived (count).
- **Sections**: a sentence-case label in 12pt `ink2` with a trailing mono
  count — "Open 3", "Projects 12", "Pinned 2", "Today 4".
- **Rows**: one line, 30pt, 13pt Inter title in `ink`, trailing metadata in
  mono `ink2` — the compact time, or `project · time` in lists that span
  projects. The open conversation is `hover2` with a 500-weight title.
  Hover shows the row's actions (archive, pin, close) in place of the
  metadata. Pinned rows keep a small pin mark in `ink3`.
- **Gliding hover**: one `hover` fill follows the pointer from row to row with
  a 140ms ease-out-strong slide. Reduced motion swaps the slide for an instant
  move.
- Multi-selection draws a 1px `accent` ring over the row's fill, and a
  keyboard highlight draws `hover` plus a `lineStrong` ring.

## State vocabulary

| State     | Mark                                                         |
|-----------|--------------------------------------------------------------|
| Starting  | Pixel loader, `ink3`.                                         |
| Working   | Pixel loader in `accent`: a 3×3 grid of 2.5pt squares with a travelling highlight. Reduced motion: a steady grid, centre lit. |
| Finished, unread | A 6pt `accent` dot.                                   |
| Idle      | Nothing.                                                     |
| Ended     | `ink3` dot; with a failure code, a `red` dot.                  |

Status pills (connected, failed, completed) are Beautiful UI's: 11.5pt text
on the colour's tint, `chip` radius.

Every interactive element ships default, hover, pressed, focused (2px `accent`
ring, 2px offset on the web, 1px on the Mac), disabled (40% opacity), and —
where it applies — selected and loading.

## Controls

- **Primary button**: `accentFill`, white 500 text, `control` radius, 28pt on
  the Mac, 44pt on the phone. Hover lightens a step and stays at 4.5:1.
- **Secondary button**: `hover2` fill, `ink` text. Hover `hover2` lifted 4%.
- **Icon button**: 24pt square, 16pt glyph in `ink3`, `hover` fill and `ink`
  glyph on hover.
- **Segmented control**: `inset` pill track, `surface` thumb with the `button`
  ring, 150ms slide.
- **Key cap**: mono 10.5pt `ink2` on `hover` with a `lineStrong` ring, `chip`
  radius.
- Menus, context menus, alerts, and the Settings window's tabs stay native.
  Beautiful UI does not reinvent standard affordances; neither does Sigil.

## Motion

- 120–160ms, `ease-out` for colour and opacity, ease-out-strong
  `cubic-bezier(.23,1,.32,1)` for anything that moves.
- A shimmer runs across the "Working" label while a turn is in flight: a soft
  highlight band, 1.6s per pass.
- No page-load sequences. Every animation has a reduced-motion answer: a
  crossfade, or the end state.

## System appearance

`NSApp.appearance` follows the terminal theme: a dark theme gives `darkAqua`
and the dark token set; a light theme gives `aqua` and the light set. Controls
are tinted `accent`, so a default button is Beautiful UI blue, never system
blue.

## The web surfaces

The website (`Site/`) and the phone companion (`Sidereal/`) use the same tokens
through CSS custom properties, `prefers-color-scheme` choosing the set. They
follow the same type, radii, rings, and motion. On the phone every tap target
is at least 44px, and the composer is Beautiful UI's prompt bar: a `surface`
card with the `card` ring, the text area on top, and a row of controls with a
round accent send button at the trailing edge.
