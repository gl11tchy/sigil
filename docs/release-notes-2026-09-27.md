# Product hardening — 2026-09-27

Release status and exact artifact receipts are recorded in
[PR #121](https://github.com/gl11tchy-team/sigil/pull/121).

## Changes

- Remote menus show available operation context and the provider's literal choices.
  They are labeled terminal controls, not verified approvals. Generic menus no
  longer invent a Yes action. Structured answers without verified identity fail closed.
- Titles, silence and live processes no longer claim that a turn finished.
  Matched Grok and known Codex journal events can confirm completion. Failure,
  stop, unknown state and attention hints stay distinct.
- Claude Code and Codex history can be found, reopened and restored by native
  conversation identity. Missing references remain saved. Provider histories stay
  read-only; Sigil's notes, names and archives stay separate. Native transcript and
  Codex title-index changes refresh automatically without a manual reload.
- Fresh client nonces and ordered events reject replayed host traffic. Uploads
  bind to a connection and tab. Timeouts do not dispatch queued keys or retry work.
- Phone drafts stay with the correct Mac and native conversation, including
  delayed replies, reconnects and restarts outside the visible tab-list limit.
- A restored terminal receives its pending keyboard focus when it joins an already
  active window. Late view attachment no longer loses that startup request.
- Sessions start only after their CLI check passes. Startup checks and history
  loading preserve saved tab order. Failed checks leave existing work running.
- CI now requires the actual iPhone app and notification/Live Activity extensions,
  plus app-hosted simulator tests through the real relay.

## Upgrade and limits

Update the Mac app and phone clients together. Older endpoints receive an upgrade
error; the new clients do not silently use the less fresh protocol.

The CI runner now uses a pinned Xcode 26.5 image with iOS 26.5. Guest toolchain
checks protect base publication; the old image remains available for rollback.
Swift caches are isolated by Xcode and compiler version.

Claude completion observation and newly launched Codex identity remain limited.
There is no provider-accepted or exactly-once approval guarantee. Text-only
Claude/Codex interactive resume passed separately from CI. Physical push, provider
tool approvals, expired-account recovery and distribution signing remain separate checks.

See [verification evidence](qa/product-hardening/README.md) and
[provider capabilities](provider-capabilities.md).
