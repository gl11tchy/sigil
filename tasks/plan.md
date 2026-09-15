# Implementation Plan: Quiet sidebar, drop photos into chat

## Overview

The left rail is one list of projects. Recents and Archived are rows you open,
not header chrome. New chat is the plus on a project. Archive is on the row.
Dragging a photo into the session pastes it the way Grok's TUI already
understands.

Skills: using-agent-skills, write-like-i-want, planning-and-task-breakdown, spec-driven-development, impeccable, frontend-ui-engineering, write-swift, apple-design, test-driven-development, incremental-implementation, debugging-and-error-recovery, security-and-hardening, git-workflow-and-versioning, code-review-and-quality, babysit-prs

Visual-direction-by-generation skipped: this is a distill of Sigil Neon, not a new look.

ASSUMPTIONS:
1. Home is the project list. Recents and Archived are drill-in rows.
2. Folder-scope and the Recents/Projects pills go away.
3. Archive a project archives every chat in that folder.
4. A dropped photo becomes a pasted absolute path (Grok turns image paths into chips). Clipboard images are written to cache first.
5. Top bar and right panel stay.

## Architecture Decisions

- `SidebarOrganization.listKind` keys off drill-in (folders / recents / archived / project), not a Recents/Projects mode.
- Drop handling lives in SigilKit (`TerminalDrop`) so paste and Finder drops share one path builder.
- SwiftTerm has no `NSDraggingDestination`. The pane container and the paste override supply it.

## Task List

### Phase 1: Photo drop
- [x] Task 1: `TerminalDrop` builds paste text from file URLs and image bytes. Paste and Finder drops send it through the PTY.

### Phase 2: Quiet sidebar
- [x] Task 2: Drill-in list kinds. Recents and Archived are rows. Archive is a row action for chats and projects.
- [x] Task 3: Remove the mode pills, folder-scope, archivebox header, and footer. Plus on a project starts a chat.

### Checkpoint
- [x] Swift tests pass
- [x] App builds and the real window is checked (sidebar + a photo drop)
