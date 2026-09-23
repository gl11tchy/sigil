# Frontend pass — 2026-09-23

Screenshots come from an isolated test build (`SigilUX`, separate bundle id and
home folder, fake Grok CLI, in-memory pairing store) paired to a local Sidereal
relay through a Chromium page at 390 × 844. No personal sessions were touched.

## Mac

- [Home with the Open section](mac-home-working.png): the two open sessions sit
  above the projects; the first is working (light on the row, the tab, and the
  screen edge) and is the selected fill.
- [Tab strip before](mac-tab-strip-before.png): two long titles pushed the first
  chip under the sidebar toggle (`'ies hold it ×`). Chips now share the strip and
  truncate, and only scroll below 96pt each.
- [Pairing pane](mac-pairing-pane.png): the code, the copy link and the expiry all
  fit; the button reads Cancel until a phone has paired.

## Phone

- [Before](phone-before.png): three rows of chrome (brand, picker, status) above
  the output, a `Sessions` text button that read as a label, and a lone `Keys`
  button under the composer.
- [Working](phone-working.png): one header row (mark, session title, New, the
  connection dot), one status row (Working · Stop · Chats · Find), and the keys
  toggle inside the composer beside the paperclip.
- [Chats sheet](phone-chats.png): open sessions with their state, and saved
  chats when you search.
- [320px](phone-320.png): nothing overflows at the narrowest phone width.

## Handoff

Every send in these screenshots left the phone and landed in the Mac's PTY; the
Mac's working state showed on both surfaces within the next poll, and a session
started from the phone's New sheet opened as a tab on the Mac.

## Production (2026-09-23)

Sidereal deployment `c8b32797` serves revision `199cc86`. The same test build
paired through `https://remote.sigilapp.dev`, started a session from the phone's
New sheet, and sent a message:
[phone](phone-production-working.png) · [Mac](mac-production-working.png).
