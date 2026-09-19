# Implementation Plan: Phone remote that you can actually use

Skills: using-agent-skills, impeccable, frontend-ui-engineering, planning-and-task-breakdown, spec-driven-development, test-driven-development, incremental-implementation, write-swift, security-and-hardening, apple-design, git-workflow-and-versioning

ASSUMPTIONS: Readable companion, not a pixel TUI. Attach writes to SigilDrops and pastes a path, same as Mac drag-drop. Visual lane is Sigil Neon. Image-gen mocks skipped: DESIGN.md is the contract and the screenshot is the defect.

## Architecture Decisions
- Strip the current Grok 4.6 composer (`Shift+Tab:mode`, `| >`, stacked rules) and collapse space-padded TUI rows that wrap into a black void on a phone.
- `file` action carries base64 chunks under the existing 64 KB plaintext / 100 KB frame caps. Mac assembles, writes, pastes the path.
- One attach control uses the iOS file sheet (library, camera, Files).

## Task List

### Phase 1: Readable output
- [x] Task 1: Failing tests for the live Grok 4.6 footer and space-padded rows.
- [x] Task 2: `readableOutput` strips that chrome and keeps drafts.

### Phase 2: File upload
- [x] Task 3: Failing tests for chunk assembly, size, names, and PTY paste.
- [x] Task 4: `file` action + `RemoteUpload` + `TerminalDrop.writeRemoteFile`.

### Phase 3: Phone UI
- [x] Task 5: Attach, chips, Stop while working, composer layout.
- [x] Task 6: Playwright + native tests, then Railway. Evidence: `tasks/verify.md`.

## Risks
| Risk | Mitigation |
|------|------------|
| HEIC decode fails in Safari | Fall back to original bytes if ≤ 4 MB |
| iOS PWA stale cache | Bump service-worker cache name |
| Chunk DoS | 4 pending transfers, 4 MB, 128 chunks, 60 s expiry |
