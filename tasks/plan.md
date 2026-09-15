# Implementation Plan: Agentic sidebar, drop the browser

## Overview

Make the left sidebar work like an agent IDE: projects you open, new chats
inside a folder, close on the row. Delete the right-panel Browser. Shell and
notes stay.

Skills: using-agent-skills, impeccable, frontend-ui-engineering, planning-and-task-breakdown, test-driven-development, incremental-implementation, write-swift, apple-design, git-workflow-and-versioning, code-review-and-quality

ASSUMPTIONS:
1. Remove Browser only. The right panel keeps Terminal and Notes.
2. Projects is a folder list you click into (`focusedProject` already exists).
3. Hover X closes an open tab, or deletes a closed chat (existing confirm).
4. Unset sidebar sort defaults to Projects. A stored Recents value stays.

## Architecture Decisions

- Wire `openProject` / `leaveProject` in the sidebar. Do not add a second model.
- Search with no focused project still lists matching chats by folder.
- ⌘T and the sidebar + use the focused project folder when one is open.

## Task List

### Phase 1: Browser gone
- [ ] Task 1: Right panel has Terminal and Notes only. Stored `web` becomes shell.

### Phase 2: Sidebar as an agent list
- [ ] Task 2: `SidebarOrganization.listKind` picks project list, focused chats, or recents.
- [ ] Task 3: Project rows open a folder. Header + and row + start a chat there. Hover X closes or deletes.

### Checkpoint
- [ ] Swift tests pass
- [ ] App builds and the real window is checked
