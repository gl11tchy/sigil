# Claude Code: structured-transcript decision

Checked **2026-10-18** for REA-1175 / mission M6. This record does not implement an Agent SDK
client, hooks or a transcript UI.

| Evidence | Version or boundary checked |
| --- | --- |
| Sigil repository | `aa06ac94aa0322d4c40b854e5aa2997e3c60de2a` |
| Existing CLI contract | Claude Code **2.1.283**, from Sigil's checked baseline and synthetic JSONL records; no installed CLI was invoked |
| Structured protocol | Documented print-mode `json` / `stream-json`; no release-pinned event-schema version was established |
| Later documented behavior | The current session guide explicitly marks running-background-session resume behavior as changed after **2.1.285**; do not project it onto 2.1.283 |

## Official channels

The [programmatic CLI guide](https://code.claude.com/docs/en/headless), accessed 2026-10-18,
documents `claude -p`, final JSON with session metadata, and newline-delimited `stream-json`.
Partial streaming requires the documented options; deltas and final results are different
records. The guide also points to the Agent SDK. These run an agent programmatically; they are
not a copy of terminal escape sequences.

The [CLI reference](https://code.claude.com/docs/en/cli-reference), accessed the same day,
distinguishes interactive `claude`, print mode, explicit resume and session forks. A fork
deliberately changes identity; continuing a saved conversation is not a read-only observation
operation.

The [current session guide](https://code.claude.com/docs/en/sessions) documents attachment to a
running background session, with a relevant restriction: output-reading flags such as
`--output-format json` prevent that attachment and cause the command to exit without sending.
Its version boundary is 2.1.285. This is evidence against treating print-mode JSON as a
transparent observer of an existing interactive/background session, not evidence that Claude has
no background-session support.

## Repository and synthetic evidence

[NativeSessionScannerTests.swift](../../../Tests/SigilKitTests/NativeSessionScannerTests.swift)
constructs Claude 2.1.283 records with `sessionId`, `cwd`, `version` and message content, plus
explicit title records. Its generated `ClaudeTranscriptFixture` and malformed/rewritten-record
cases exercise metadata parsing and incremental history handling.
[HistoryCompatibilityFixture.swift](../../../Tests/SigilKitTests/HistoryCompatibilityFixture.swift)
creates disposable provider roots and generated envelopes.

[ProviderAdapter.swift](../../../Sources/SigilKit/Terminal/ProviderAdapter.swift) allows Claude
native history/resume but does not advertise validated lifecycle or structured approval. These
tests are evidence of Sigil's current metadata projection, not an Agent SDK/control-protocol
conformance suite. Fixture source alone was inspected; no personal transcript, auth store or
live CLI was read.

## Coexistence and potential value

Read-only, validated history metadata already accompanies the real PTY. A future message adapter
could preserve roles, content blocks and tool results for richer navigation. Subagent messages,
partial deltas, compaction and forks would need distinct handling; concatenating every assistant
record would not establish the original conversation.

Launching an SDK/print run or resuming the same ID in another process changes the writer/control
topology. The reviewed documentation does not establish a supported structured mirror of Sigil's
arbitrary current TUI session. Background attachment is a separate documented topology with its
own version and output restrictions.

## Identity, security and unresolved assumptions

Retain provider + native session + workspace and owned-process generation boundaries; a tab UUID
or matching directory is insufficient. Read complete bounded records and invalidate stale
projections on replacement, identity changes and malformed data. File content, quoted tool
output and historical permission-related text are untrusted display data, not a live approval
request. A future control response would require an owned authenticated channel, current request
identity and explicit user intent.

The current rolling docs are not a compatibility guarantee for 2.1.283 or a stable on-disk
schema. No concurrent-writer, SDK approval, replay or full-message fixture was validated in this
investigation. No model request or paid inference occurred.

## Decision and fallback

**NO-GO for adding a native transcript or structured approvals beside the existing Claude PTY
now.** Print/SDK streaming is useful for a separately owned agent, while documented
running-session attachment does not supply the assumed JSON observer. Reconsider only with a
pinned CLI/SDK schema, an explicit ownership topology, and synthetic
message/compaction/fork/approval tests. The fallback is the provider terminal and existing
validated history, title/search and native resume; completion and approvals remain unknown where
Sigil has no independent evidence. There is no promise of a uniform transcript.
