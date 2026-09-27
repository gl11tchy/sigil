# Sigil

A native macOS home for real coding-agent CLIs, with Sidereal on the web and a
native iPhone companion. The provider's terminal remains the conversation.

## Product outcome

Start in the right project. Leave the desk. Receive an accurate alert. Inspect
what needs attention, respond, and return to the same conversation.

## Priorities

1. Remote commands target the intended session. Uncertain approvals stay ordinary,
   clearly labeled terminal input, never verified authorization.
2. State is truthful. Silence, title changes and a live process do not prove a
   completed turn. Missing evidence remains unknown.
3. Grok, Claude Code and Codex have provider-native history and resumption where
   their CLIs support it. A terminal tab ID is not a conversation ID.
4. The actual Mac app, iPhone app and shipping extensions build and receive tests.
5. Find a conversation in under two seconds in a history of at least 900 chats.

## Design

Dark, dense, keyboard-first. Preserve the terminal, the project context, and the
existing design system. No replacement chat interface or extra provider.

## Continuity and safety

History, search and restoration follow [provider capabilities](docs/provider-capabilities.md).
Missing folders, unavailable CLIs and failed resumptions retain saved references.
Native provider transcripts remain owned by their CLIs. Sigil stores its own names,
notes, pins and archives separately.

The phone shows the same identity, state and capabilities as the desktop. Commands
are not queued offline or blindly retried. A dispatch receipt proves only that
input reached the host dispatch path, not provider acceptance or successful work.

## Non-goals

Replacing provider CLIs, inventing unsupported integration, redesigning the product,
or treating a launch smoke test as proof of complete product correctness.
