# Cursor: structured-transcript decision

Checked **2026-10-18** for REA-1175 / mission M6. This record does not add an ACP client, change
the launch mode or enable a native transcript.

| Evidence | Version or boundary checked |
| --- | --- |
| Sigil repository | `aa06ac94aa0322d4c40b854e5aa2997e3c60de2a` |
| Public CLI version reference | Official CLI changelog **v2026.10.08**, checked as documentation, not an installed executable |
| Public protocol | Cursor's ACP example uses `protocolVersion: 1`, JSON-RPC **2.0**, newline-delimited stdio; print-mode event schema is a rolling documentation snapshot |
| Sigil contract | No checked Cursor CLI version or native history/approval adapter; `cursor-agent` is the selected executable name |

## Official channels

[Output format](https://cursor.com/docs/cli/reference/output-format), accessed 2026-10-18,
documents `json` and `stream-json` for print mode, not ordinary interactive output. The stream
carries session IDs, messages and tool events. Partial output can include duplicate
buffered/final assistant flushes; EOF on failure need not include a terminal result. These
semantics require a provider-specific decoder rather than concatenating all text records.

The [official ACP guide](https://cursor.com/docs/cli/acp), checked the same day, documents a
separate `agent acp` stdio process. Its example initializes protocol version 1; sessions and
streamed updates have explicit methods, and permission decisions require responses. Cursor also
has blocking extensions for questions and plan review. The example client's automatic permission
answer is not an appropriate approval policy for Sigil.

The [CLI changelog](https://cursor.com/docs/cli/changelog) identifies v2026.10.08 and an ACP
background-shell wakeup change. It is a checked version reference, not a release-pinned schema
or proof that a final text message means the whole prompt has settled. No binary or model was
run.

## Repository and synthetic evidence

[CLIProvider.swift](../../../Sources/SigilKit/Terminal/CLIProvider.swift) deliberately selects
`cursor-agent`, because Grok also installs an `agent` alias. The synthetic
`cursorUsesItsUnambiguousCLIName` and provider-argument cases in
[CLIProviderTests.swift](../../../Tests/SigilKitTests/CLIProviderTests.swift) protect that
distinction. [ProviderAdapter.swift](../../../Sources/SigilKit/Terminal/ProviderAdapter.swift)
currently exposes no native Cursor history, resume, lifecycle or structured approval through
Sigil.

These are launch fixtures, not Cursor JSONL history or ACP conformance fixtures. No on-disk
transcript schema was established from them, and neither another provider's JSON keys nor a
user's private Cursor data store was used as a substitute. Fixture source was inspected without
execution.

## Coexistence and potential value

Print/ACP could provide roles, tool calls, deltas and explicit questions for an independently
owned integration. ACP is intended to drive an agent from a custom client; it is not evidence
that Sigil can tap an arbitrary interactive `cursor-agent` PTY without changing its session
ownership.

A future adapter could improve per-message actions and tool-state presentation, but it would
have to preserve Cursor-specific extensions, modes and pending operations. Sharing ACP framing
with another provider does not make their transcript or approval semantics interchangeable. No
reviewed source establishes the required passive existing-PTY attachment or concurrent-writer
arbitration.

## Identity, security and unresolved assumptions

Pin the actual Cursor executable, not the ambiguous `agent` alias, and validate the advertised
protocol/capabilities before any future integration. Bind the owned transport/process
generation, native session and current tool/request IDs; do not map a directory, terminal title
or session-list row to a live tab by inference.

Treat tool output and historical events as untrusted display content. Never copy automatic
approvals from a sample client. A future spec must distinguish tool permission, a question and
plan acceptance, reject replies after cancellation/reconnect, and bound
partial/duplicate/incomplete streams. Current documentation and launch fixtures do not verify
those behaviors or a disk-history recovery contract. No credentials, permission policy or
personal history was inspected or changed here.

## Decision and fallback

**NO-GO for adding a structured transcript or approvals to Sigil's current Cursor PTY path.**
Print-mode JSON and ACP are documented, but the checked host evidence proves only launch
behavior and does not establish same-session coexistence, identity or safe control semantics.
Reconsider a separately scoped, version-pinned ACP integration with synthetic extension, replay,
duplicate-output and permission tests. Keep the real interactive `cursor-agent` terminal and
current terminal/phone output as the fallback; unsupported native history and authorization
remain unavailable. There is no uniform transcript promise.
