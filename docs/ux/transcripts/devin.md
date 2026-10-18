# Devin: structured-transcript decision

Checked **2026-10-18** for REA-1175 / mission M6. This record concerns the local `devin` CLI
that Sigil launches, not a new Devin Cloud session or an integration implementation.

| Evidence | Version or boundary checked |
| --- | --- |
| Sigil repository | `aa06ac94aa0322d4c40b854e5aa2997e3c60de2a` |
| Public CLI version reference | Stable changelog **v3000.11.92**, dated **2026-10-14**, inspected as documentation; no installed binary was probed |
| Structured protocol | Documented ACP over JSON-RPC/stdin/stdout. No exact negotiated ACP revision or binary-specific schema was validated |
| Sigil contract | No checked Devin version or native history adapter in `CLIProvider`; rolling public docs do not add either capability |

## Official channels

The [official Commands & Flags reference](https://docs.devin.ai/cli/reference/commands),
accessed 2026-10-18, documents `devin acp` as a subprocess for an ACP editor/client, using
JSON-RPC over stdin/stdout rather than an interactive terminal. It also documents
non-interactive `--print`, native session resume and JSON output for session listing. JSON
session-list output is not evidence of a streamed transcript format for print mode. The ACP
entry point can use existing CLI authentication or an ACP authentication request.

The [stable changelog](https://docs.devin.ai/cli/changelog/stable), checked on the same date,
identifies v3000.11.92 and describes moving the session-history database with
`DEVIN_SESSIONS_DIR`. It also mentions force-opening sessions held elsewhere. Neither is a
documented stable on-disk message schema or a safe passive-observer contract.

The [official quickstart](https://docs.devin.ai/cli) distinguishes local Devin CLI from cloud
Devin. Cloud session APIs and handoff do not establish a control channel to the local PTY that
the user already has open.

## Repository and synthetic evidence

[CLIProvider.swift](../../../Sources/SigilKit/Terminal/CLIProvider.swift) selects `devin`;
[ProviderAdapter.swift](../../../Sources/SigilKit/Terminal/ProviderAdapter.swift) leaves native
history, resume, lifecycle and structured approval unavailable for this provider in Sigil. This
is a host capability boundary, not a claim that Devin itself has no session history.

The generated launch/environment cases in
[CLIProviderTests.swift](../../../Tests/SigilKitTests/CLIProviderTests.swift) verify
provider-specific arguments and removal of Grok-only state. They do not construct Devin
transcript, ACP approval or local/cloud identity fixtures. Only repository source was read; no
personal Devin database, credentials or live CLI was inspected and no fixture was executed here.

## Coexistence and potential value

ACP could supply explicit message/tool updates and request/response boundaries to a future
custom client. That is stronger evidence than scraping a TUI. It also puts the client in charge
of a subprocess and session operations, rather than making it a transparent second reader of
Sigil's current terminal.

The reviewed sources do not establish a passive attachment to an arbitrary active local PTY. A
second resume, a forced open or a cloud handoff must not be used to infer such coexistence. A
future spec must first establish one writer and an exact mapping between the local provider
session and the Sigil tab/process generation.

## Identity, security and unresolved assumptions

Keep local and cloud session namespaces, accounts, workspaces and transport generations
separate. An ID from JSON session listing or a matching directory cannot prove that it belongs
to the currently owned terminal. Never extract account credentials or duplicate them into Sigil
for this investigation.

A future ACP adapter must pin and negotiate its schema/capabilities, retain each live permission
request's identity, handle interruption and reconnect, and reject stale or historical approvals.
It must respect the existing workspace trust and permission policy; changing flags to make
unattended print mode run would change the security boundary. No local database schema,
concurrent-session behavior, replay or authenticated protocol interaction has been verified
here. The public changelog label is not a claim of binary compatibility.

## Decision and fallback

**NO-GO for a structured transcript or approval layer on the current Devin PTY path.** ACP is a
credible separate client mode, but the reviewed evidence does not bind it to Sigil's existing
process or supply a checked native-history schema. Reconsider after a provider-specific
ownership/authentication spec and synthetic version, identity, replay and permission tests; do
not force-open a live session to obtain events. The fallback is the real interactive CLI and
existing terminal/phone output, with unsupported history, completion and approval capabilities
reported truthfully. No uniform transcript is promised.
