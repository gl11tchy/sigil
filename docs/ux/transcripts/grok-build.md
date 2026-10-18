# Grok Build: structured-transcript decision

Checked **2026-10-18** for REA-1175 / mission M6. This is a decision record, not an integration
or a new supported capability.

| Evidence | Version or boundary checked |
| --- | --- |
| Sigil repository | `aa06ac94aa0322d4c40b854e5aa2997e3c60de2a` |
| Existing CLI contract | Grok **1.0.40**, as recorded in `CLIProvider.checkedVersion`; not an installed-version probe in this investigation |
| Public protocol | ACP example negotiates `protocolVersion: 1` over JSON-RPC 2.0; headless formats are `plain`, `json`, and `streaming-json` |
| Source edition | Official pages accessed 2026-10-18; Headless & Scripting says last updated 2026-06-10. Rolling documentation is not a schema pinned to Grok 1.0.40 |

## Official channels

The [official headless guide](https://docs.x.ai/build/cli/headless-scripting) documents `-p` /
`--single` for a non-interactive prompt, including a final JSON result or newline-delimited
`streaming-json` events. It also documents `grok agent stdio`: an ACP process whose
`session/update` notifications carry assistant chunks, while `session/prompt` returns completion
metadata. Its example initializes protocol version 1. These are different modes from the
interactive TUI.

The [CLI reference](https://docs.x.ai/build/cli/reference), checked on the same date,
distinguishes the default TUI, ACP, native session resume, and Markdown transcript export.
Export is a retrospective document, not a live approval channel.

## Same-session hooks

The [official Hooks reference](https://docs.x.ai/build/features/hooks.md), fetched 2026-10-18,
documents commands/HTTP callbacks from the interactive session. JSON stdin includes `sessionId`,
`hookEventName`, workspace fields and tool input; prompt, tool, session, stop/failure and
compaction events are available. This is a genuine same-session observation route without a
second agent writer. The documented contract does not establish assistant-text deltas, message
IDs or native turn IDs for a complete transcript.

Project/personal Grok JSON files and compatible Claude/Cursor files can supply hooks. Project
hooks require trust, which also covers other project extensions; Sigil must not grant that trust
automatically. Only `PreToolUse` blocks; passive-event stdout is ignored. Timeouts, malformed
output and crashes fail open. A future passive collector should use nonblocking event semantics,
bounded local delivery and no permission decisions. These rolling docs do not certify hook
availability/schema in the checked 1.0.40 baseline; no hook was configured or executed.

## Repository and synthetic evidence

[ProviderAdapter.swift](../../../Sources/SigilKit/Terminal/ProviderAdapter.swift) records the
checked CLI version and keeps `structuredApproval` false.
[HistoryCompatibilityFixture.swift](../../../Tests/SigilKitTests/HistoryCompatibilityFixture.swift)
generates Grok `summary.json` records with native ID and working directory. The `grok` builder
in
[ProviderLifecycleJournalTests.swift](../../../Tests/SigilKitTests/ProviderLifecycleJournalTests.swift)
generates journal envelopes with `params.sessionId`, `_meta.eventId`, `_meta.promptId`,
timestamps and `update.sessionUpdate`; tests reject mismatched sessions/turns and incomplete
evidence.

Those fixtures support Sigil's existing history and lifecycle boundaries. They do not validate
complete message reconstruction, an ACP client, or actionable approvals. They were read as
source, not executed here; no personal session directory was inspected.

## Coexistence and potential value

The existing read-only journal can coexist with the CLI's PTY. A complete, identity-bound
message projection could eventually make per-message copying and navigation more reliable than
terminal-text heuristics. The present fixtures establish a narrower lifecycle projection, not
that transcript contract.

Hooks offer a narrower alternative to extending the journal. Starting a second headless or ACP
process would make Sigil an agent client and possible writer. Reusing a session ID is not
evidence that concurrent ownership is supported. This is a different topology from observing the
user's current terminal and needs an explicit provider-specific spec.

## Identity, security and unresolved assumptions

A future adapter must bind the provider-native session and current process generation before
consuming events; `cwd`, a title or recent-file time cannot establish ownership. Validate
complete bounded records, event/turn correlation, truncation, replacement, replay and
unsupported schemas before publishing state. A history event or Markdown export cannot authorize
an operation. Any future ACP permission response must belong to a still-live request on the
owned connection and must not silently auto-approve.

A hook's claimed session ID is not authenticated tab ownership. A future collector needs an
owned launch/collector generation, independent native-session binding, bounded untrusted
payloads and explicit loss/duplicate handling. Preserve existing user hooks; collecting events
must not rewrite tool inputs, add context, grant trust or change approvals.

The rolling ACP/headless documentation has not been validated against the 1.0.40 baseline or a
complete synthetic transcript/approval fixture. Concurrent resume, event completeness, stable
message IDs and recovery after interruption remain unproven. This investigation started no CLI
or model call.

## Decision and fallback

**NO-GO for adopting a native transcript or structured approvals for the existing Grok PTY
now.** **GO for a separately scoped read-only hook/lifecycle specification**, because it can
observe the same interactive agent. Its documented coverage does not supply a complete message
transcript, and the baseline/version and identity contract still need synthetic proof.
Reconsider adoption after pinning the executable/schema and validating identity, loss/replay,
messages and pending approvals; ACP/headless would require a separate ownership design. The
fallback remains the real terminal, its Find/phone output, and only the currently validated Grok
history, resume, export and lifecycle capabilities. No uniform cross-provider transcript is
promised.
