# Codex: structured-transcript decision

Checked **2026-10-18** for REA-1175 / mission M6. This record selects no implementation and
starts no app-server or model request.

| Evidence | Version or boundary checked |
| --- | --- |
| Sigil repository | `aa06ac94aa0322d4c40b854e5aa2997e3c60de2a` |
| Existing CLI baseline | Codex **0.157.1**; synthetic newer metadata cases include **0.158.0** and **0.160.0**. These are repository contracts, not installed/current-version probes |
| Public protocol | App-server's documented JSON-RPC **2.0** framing and current thread/turn/item API, including its v2 approval schema; no binary-specific generated schema was produced |
| Source edition | Official OpenAI documentation accessed 2026-10-18. Rolling protocol documentation is not a claim that every feature exists in 0.157.1 |

## Official channels

[Codex app-server](https://developers.openai.com/codex/app-server/) documents bidirectional
JSON-RPC 2.0 with the `jsonrpc` header omitted, default JSONL stdio, initialization, streamed
items and live approval requests. Its schemas can be generated for the exact CLI version. The
reviewed page scopes approvals with thread, turn and item identities.

[Non-interactive mode](https://developers.openai.com/codex/noninteractive), checked on the same
date, separately documents `codex exec --json`: JSONL thread/turn/item events for a programmatic
run. A requested final JSON schema structures the answer; it does not turn another TUI process
into an event source. A stream ending without valid completion is not proof of success.

## Repository and synthetic evidence

[NativeSessionScannerTests.swift](../../../Tests/SigilKitTests/NativeSessionScannerTests.swift)
generates `session_meta` envelopes, newer compatible versions, malformed identities and
unsupported majors.
[ProviderLifecycleJournalTests.swift](../../../Tests/SigilKitTests/ProviderLifecycleJournalTests.swift)
separately constructs `event_msg` records and verifies native-session and turn matching.
[CodexTabBindingTests.swift](../../../Tests/SigilAppTests/CodexTabBindingTests.swift) covers the
independent owned-process/transcript binding boundary.

A valid newer history envelope does not certify an event schema, successful turn or live tab
binding. The current code's kernel process-generation/file identity lease must not be replaced
with a `cwd`/time guess. The repository has no validated app-server transcript/approval adapter.
Only generated fixture source was inspected; no private rollout or CLI home was opened and no
tests or CLIs were run for this document.

## Coexistence and potential value

The current [app-server documentation](https://developers.openai.com/codex/app-server/)
explicitly supports connecting a terminal UI with `codex --remote` to a server. This is a
documented future shared-server topology, not an unavailable feature. The page labels WebSocket
transport experimental and unsupported for production; that transport warning must not be
generalized to default stdio.

That still does not establish an observer for an arbitrary already-running Sigil TUI. An opt-in
server/remote-TUI launch would change ownership. Item boundaries, diffs and live approvals could
be useful, but a Sigil spec must assign the client that can start, steer or interrupt a turn and
answer each request.

## Identity, security and unresolved assumptions

A future spec must pin the executable and generated schema, own its authenticated/local
transport, and correlate connection generation, provider thread, turn, item and pending request.
Replayed disk items are display evidence only. Stale requests, cancellation, reconnect and
conflicting clients must never transfer approval authority. Terminal text and successful history
parsing remain insufficient authorization.

No multi-client arbitration, arbitrary-TUI attachment, schema upgrade or reconnect/replay
behavior was validated here. The documented server route is a real candidate for further
investigation, not a tested Sigil capability. No listener, token or permission configuration was
created or changed.

## Decision and fallback

**NO-GO for adopting app-server as a native transcript/approval layer for the current Codex PTY
path now.** The documented shared-server terminal route is more promising than a second headless
conversation, but Sigil's launch, identity and client-arbitration contract for it remains
unvalidated. Reconsider a separate opt-in integration spec with a supported transport, pinned
schemas and synthetic ownership, event, replay and approval cases. Keep the actual terminal plus
existing validated history/resume and separately verified lifecycle/tab identity as the fallback.
Do not promise a uniform provider transcript.
