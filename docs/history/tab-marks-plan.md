Shipped in [#128](https://github.com/gl11tchy-team/sigil/pull/128); kept for history.

# Implementation Plan: Name and color a tab

Skills: using-agent-skills, planning-and-task-breakdown, frontend-ui-engineering, test-driven-development, write-swift, code-review-and-quality, git-workflow-and-versioning

ASSUMPTIONS: A tab rename is the conversation name the sidebar already stores. Claude, Cursor, and the other agents keep a name only while that tab is open. The color is one of the five Sigil marks, drawn as a bar, not a second dot. No color means the tab looks as it does today.

## Task List

- [x] Task 1: Failing tests for saving a color, clearing a name, and keeping two folders apart.
- [x] Task 2: Save the color with the conversation. Rename from the tab uses the existing name.
- [x] Task 3: Right-click menu on the tab. Inline rename. Color bar on the tab and in the tab list.

## Checkpoint

- [x] Focused tests pass.
- [x] A tab with no color matches the current chip.
