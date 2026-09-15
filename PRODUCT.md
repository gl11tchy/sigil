# Sigil

A native macOS shell for the Grok Build CLI. It runs the real `grok` terminal UI in
a pseudo-terminal and adds the one thing a terminal cannot give you: every
conversation you have ever had, listed, searchable, and one click from resuming.

## Register

Product. Design serves the task. The user is mid-thought, moving between a
conversation they had this morning and one from three weeks ago. The chrome has to
disappear.

## Who uses it, and where

One developer, at a desk, in a dark room, at night, with a terminal already open on
the other half of the screen. They keep 900+ conversations. They switch between four
or five in an hour. They are never "browsing" — they are looking for one specific
thread and they half-remember its name.

That scene forces the answer: **dark, dense, keyboard-first**. Not dark because
tools look cool dark. Dark because it sits beside a terminal and must not be the
bright thing on the screen.

## What it must do well

1. Find a conversation in under two seconds, by name, without leaving the keyboard.
2. Show at a glance which conversation is open and which one is doing work.
3. Start a new chat in a project in one click, and close an old one from the same row.
4. Never get in the terminal's way. The terminal is the product; this is the frame.

## Non-goals

- Rendering the conversation itself. The CLI already does that, better.
- Settings surfaces beyond the few that change how `grok` is launched.
- Any decoration that costs a row of list density.
