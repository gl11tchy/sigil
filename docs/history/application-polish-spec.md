Shipped in [#52](https://github.com/gl11tchy-team/sigil/pull/52); kept for history.

# Sigil application quality pass

## Objective
Make existing desktop and phone workflows easier to find, read, and recover. Keep
Sigil's neutral dark surfaces, mint action accent, native desktop density, and real
terminal output. The phone is a one-handed companion, not a shrunken Mac window.

## Capability map and order
1. `mobile-workspace`: clear session header, searchable session sheet, readable
   output workspace, compact activity/stop controls, accessible tools and onboarding.
2. `remote-recovery`: visible ended/offline states; preserve drafts; command errors
   must be handled; restart ended sessions using the Mac's existing restart path.
3. `desktop-basics`: improve search across title/project terms, pairing link fallback,
   and discoverable keyboard controls without changing session storage or ownership.
4. Verify integrated behavior, native build, and project gates.

## Acceptance
- 320/390/768/1280px layouts have no page overflow, 44px phone controls, and one composer.
- Search sessions, switch with a draft, send, attach, stop, recover and raw output work.
- Connection state never masquerades as session activity. Offline drafts stay editable.
- Long titles and keyboard-height screens remain usable. Dialogs manage keyboard focus.
- Desktop search accepts terms across title and folder; each term is required.
- Pairing retains encryption and expiry; a copy action supplies the existing link.
- No real user sessions are stopped, deleted, or changed for verification.

## Structure and style
Plain ES modules in Sidereal/public; SwiftUI in Sources/SigilApp; shared Swift logic
in Sources/SigilKit. Follow existing DOM textContent rendering and Swift guard clauses.
No new runtime dependencies, frameworks, content interpretation, or remote file access.

## Checks
Behavior regression tests under Sidereal/test/browser and Tests; screenshots from
Chromium and WebKit; native isolated app inspection. Full gate: `Scripts/verify.sh`.

## Boundaries
Preserve user data, pairing protocol and terminal output. Do not publish, merge or
replace the running app as part of local verification. No unrelated infrastructure.

## Skills
using-agent-skills, spec-driven-development, frontend-ui-engineering,
incremental-implementation, test-driven-development, browser-testing-with-devtools,
git-workflow-and-versioning, write-swift, impeccable, product-design:audit.

## PR review follow-through
Skills: code-review-and-quality, test-driven-development, debugging-and-error-recovery,
api-and-interface-design, incremental-implementation.
The restart reply names the replacement tab explicitly. Drafts must follow that ID,
not whichever session the Mac has selected when it answers. Verify concurrent Mac
selection changes in browser and native tests before the release push.
