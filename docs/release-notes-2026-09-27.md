# Unreleased — product hardening

This integration has not been merged, installed or deployed.

## Changes

- Remote menus show available operation context and the provider's literal choices.
  They are labeled terminal controls, not verified approvals. Generic menus no
  longer invent a Yes action. Structured answers without verified identity fail closed.
- Titles, silence and live processes no longer claim that a turn finished.
  Matched Grok and known Codex journal events can confirm completion. Failure,
  stop, unknown state and attention hints stay distinct.
- Claude Code and Codex history can be found, reopened and restored by native
  conversation identity. Missing references remain saved. Provider histories stay
  read-only; Sigil's notes, names and archives stay separate.
- Fresh client nonces and ordered events reject replayed host traffic. Uploads
  bind to a connection and tab. Timeouts do not dispatch queued keys or retry work.
- Phone drafts stay with the correct Mac and native conversation, including
  delayed replies, reconnects and restarts outside the visible tab-list limit.
- CI now requires the actual iPhone app and notification/Live Activity extensions,
  plus app-hosted simulator tests through the real relay.

## Upgrade and limits

Update the Mac app and phone clients together. Older endpoints receive an upgrade
error; the new clients do not silently use the less fresh protocol.

The configured CI runner still needs Xcode 26+ and an iOS 26+ simulator. Local
native verification passed, but the old Xcode 16.4 runner cannot pass this gate.
No external runner or production deployment was changed.

Claude completion observation and newly launched Codex identity remain limited.
There is no provider-accepted or exactly-once approval guarantee. Physical push,
authenticated provider sessions and distribution signing were not verified.

See [verification evidence](qa/product-hardening/README.md) and
[provider capabilities](provider-capabilities.md).
