# Kimi Code: structured-transcript decision

Checked **2026-10-18** for REA-1175 / mission M6. The legacy Python `kimi-cli` and its
replacement Kimi Code must be treated as different implementation/version families. This
investigation performed no migration, installation or model call.

| Evidence | Version or boundary checked |
| --- | --- |
| Sigil repository | `aa06ac94aa0322d4c40b854e5aa2997e3c60de2a` |
| Replacement CLI version reference | Public Kimi Code changelog **2.1.1 (2026-09-24)**; a documentation reference, not an installed-version probe |
| Replacement protocols | ACP docs refer to SDK **1.x**; experimental REST `/api/v1` plus selected `/api/v2` endpoints and `/api/v1/ws`. Rolling pages were not verified against the 2.1.1 binary |
| Legacy contract | Archived `kimi-cli` **1.52.0 (2026-09-22)**; its documented Wire protocol **1.10** must not be attributed to the replacement |
| Sigil contract | No checked Kimi version or native history/structured-approval adapter |

## Official channels and the version split

The [replacement CLI
reference](https://moonshotai.github.io/kimi-code/en/reference/kimi-command.html), accessed
2026-10-18, documents non-TUI `--prompt` with text or `stream-json`, plus `kimi acp` and `kimi
web`. Prompt mode uses the automatic permission policy for regular tool calls rather than asking
a human. Switching to this mode merely to obtain JSON would change Sigil's interaction/approval
boundary.

The [replacement ACP
reference](https://moonshotai.github.io/kimi-code/en/reference/kimi-acp.html) describes stdio
JSON-RPC, initialization/capabilities, history-replaying `session/load`, and a `session/resume`
reattachment without replay. The [Server API
reference](https://moonshotai.github.io/kimi-code/en/reference/server-api.html) documents
bearer-authenticated REST and session-event WebSocket subscriptions. It labels the APIs
experimental and makes each running version's authenticated OpenAPI/AsyncAPI documents
authoritative. No local server or live schema was queried here.

The [replacement
changelog](https://moonshotai.github.io/kimi-code/en/release-notes/changelog.html) supplies the
2.1.1 version reference. The [migration
guide](https://moonshotai.github.io/kimi-code/en/guides/migration) distinguishes the legacy and
replacement implementations and describes transferring selected config/history, with
authentication separate. This does not establish transcript-schema compatibility.

The [legacy changelog](https://moonshotai.github.io/kimi-cli/en/release-notes/changelog.html)
marks 1.52.0 archived and says its default launcher downloads/runs a replacement installer. The
[legacy Wire guide](https://moonshotai.github.io/kimi-cli/en/customization/wire-mode.html)
describes Wire 1.10 over JSON-RPC 2.0, and read-only history replay whose old requests must not
be answered. That remains legacy evidence, not a guarantee for Kimi Code 2.x.

## Repository and synthetic evidence

[CLIProvider.swift](../../../Sources/SigilKit/Terminal/CLIProvider.swift) launches `kimi`.
[CLIProviderTests.swift](../../../Tests/SigilKitTests/CLIProviderTests.swift) uses generated
launch/environment cases to check its executable lookup and provider-scoped variables.
[ProviderAdapter.swift](../../../Sources/SigilKit/Terminal/ProviderAdapter.swift) has no checked
Kimi version and does not advertise native history, resume, lifecycle or structured approval.

There is no Kimi transcript/Wire/ACP fixture suite in these checked host contracts. Reading the
generated launch tests does not establish a disk format for either implementation. No personal
Kimi home, session file, token or credential store was opened; no fixture or CLI was executed.

## Same-session hooks

The [replacement Hooks
reference](https://moonshotai.github.io/kimi-code/en/customization/hooks), accessed 2026-10-18,
documents scripts running from the existing session. Base JSON stdin includes `session_id`,
event name and client/workspace fields; `TurnStarted` carries `turn_id` and prompt/origin, with
separate queued-prompt, tool/result, permission/result, interruption and session events. This
avoids a second agent writer, but the reviewed event catalog does not establish a full
assistant-message stream.

Rules live in replacement `~/.kimi-code/config.toml`, not the legacy family's configuration.
Matching hooks run in parallel. Tool/prompt/stop handlers can block or append context; other
events are observational. Errors/timeouts fail open, so missing events cannot certify success or
serve as a security boundary. A prospective collector should use confirmed observational events,
emit no control/context output and preserve user configuration. This rolling contract was not
verified against replacement 2.1.1 or any legacy binary; no hooks were installed or run.

## Coexistence and potential value

The replacement's session APIs and event subscriptions make a future read-only projection worth
investigating. ACP reattachment is documented, so it must not be dismissed as nonexistent.
However, no reviewed evidence binds that server/session to the particular `kimi` process inside
an existing Sigil PTY or demonstrates safe concurrent clients for that topology. Resuming an ID
is not proof of exclusive ownership.

A future integration could offer message navigation and explicit pending requests, but it must
select one implementation family and preserve that family's event and recovery semantics. Legacy
Wire, replacement ACP and the experimental server API are not interchangeable transcript
formats. Replacement hooks offer a narrower same-session activity route that does not require
assuming server ownership or ACP reattachment semantics.

## Identity, security and unresolved assumptions

Before reconsideration, identify the executable/version and owned connection generation,
negotiate/pin capabilities and schemas, and map provider-native session plus turn/tool/request
identity. A local bearer endpoint carries access authority; loopback alone is not authorization,
and no bypass-auth option should be introduced for this feature. Historical/replayed requests
cannot become current approvals. Separate display-only subscriptions from prompt, interrupt,
permission and session mutation methods.

Hook IDs also need an owned collector/launch generation plus independent tab/native-session
binding. Do not trust arbitrary local JSON or infer turn IDs on events that omit them. Bound
payloads and specify ordering, loss, duplicate/queued prompts and stop continuation before
showing completion; keep permission events informational unless a separately authorized live
control channel exists.

The exact installed implementation, replacement disk schema, schema-to-release mapping, replay
ordering and live multi-client arbitration remain unverified. The difference between rolling
reference pages and the dated release label is an explicit limit, not permission to assume
compatibility. No integration or uniform cross-provider mapping is selected.

## Decision and fallback

**NO-GO for a native transcript or structured approval layer on the current Kimi PTY path.**
**GO for a scoped replacement-family read-only hook/activity specification**, because documented
callbacks can observe the current agent. Full transcript adoption needs assistant-message
coverage, a checked family/version/identity adapter and synthetic ordering, loss, queued-prompt,
continuation and permission cases; legacy Wire cannot fill those gaps. Server/ACP control needs
a separate authentication/ownership design. The fallback remains the actual interactive `kimi`
terminal and existing terminal/phone output, with unsupported native history/completion/approval
capabilities unavailable; do not auto-migrate or launch another agent to manufacture a
transcript.
