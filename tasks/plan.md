# Implementation Plan: App dark themes

Skills: using-agent-skills, spec-driven-development, planning-and-task-breakdown, impeccable, frontend-ui-engineering, write-swift, apple-design, test-driven-development, incremental-implementation, git-workflow-and-versioning, code-review-and-quality, babysit-prs

ASSUMPTIONS: 16 app dark themes, existing four kept, chrome greys stay neutral, picker wraps to 4 columns, CLI name stays `groknight` except Sigil Neon / Grok Day.

## Architecture Decisions
- Each `TerminalTheme` stores its hex palette and chrome accent. No name-switch fallback for new themes.
- Brand accents lift toward white until they clear WCAG AA as chrome text on the selected row.
- Settings uses a 4-column grid of the existing `ThemeCard`.

## Task List

### Phase 1
- [x] Task 1: Failing tests for 16 named dark themes, unique names/grounds, CLI fallback.
- [x] Task 2: Palettes that pass TerminalThemeTests and PaletteTests.
- [x] Task 3: Wrap the Appearance theme picker so 20 swatches fit.

### Checkpoint
- [x] Focused tests pass
- [x] Settings picker lays out every theme in a measured 4-column stack
- [x] Palettes compiled into the debug binary; second GUI instance could not show a window while the live app holds the bundle ID
