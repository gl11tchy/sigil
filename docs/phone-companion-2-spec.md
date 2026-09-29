# Spec: phone companion, second wave

## Objective

The iPhone app becomes a real remote for Sigil, not a polling viewer:

- An alert reaches the phone when a session finishes a turn or asks a question,
  and a working session shows on the Lock Screen, so the app can be closed.
- When an agent asks for approval, the phone shows Yes, No and numbered buttons.
- Output shows the terminal's colours.
- The Mac sends each change as it happens; the phone no longer polls once a second.
- Sessions can be closed, renamed and archived from the phone, each shows its
  provider, and a new session can start in a new worktree, as on the Mac.
- The last output shows the moment the app opens.
- One phone pairs with more than one Mac.

## Capability map

| Module id | Responsibility | Depends on |
|---|---|---|
| live-stream | Mac pushes row-level, styled screen changes; phone renders colours; last screen cached on disk | — |
| session-ops | Provider per tab; close, rename, archive; new session in a worktree | live-stream (tab fields) |
| approvals | Mac detects an approval prompt on screen; phone shows answer buttons | live-stream (event frames) |
| alerts | APNs through the relay; sealed alert payloads; Live Activity with push updates | live-stream, approvals |
| multi-mac | Several pairings on the phone; a Mac picker; alerts route to the right Mac | alerts |

Build order: live-stream → session-ops, approvals → alerts → multi-mac.

## Assumptions

1. The web companion keeps working unchanged: it ignores event frames (a sealed
   reply with a sequence it does not wait on) and unknown fields.
2. Tab status values stay `starting | working | idle | exited`; new facts travel
   in new fields, because the web client rejects unknown statuses.
3. The relay stays stateless across restarts; a Mac re-sends the phone's push
   token on every host connect.
4. The relay holds the APNs key (`AuthKey_NX5CWFDJZL.p8`, team CDAQ9PW7QF) as
   environment variables on Railway. Alert text is sealed with the device key
   and decrypted by a Notification Service Extension, so neither the relay nor
   Apple reads session titles. Live Activity pushes carry only a status word and
   a timestamp; the title is set on the phone when the activity starts.
5. Approval prompts are recognised from the last screen rows, per provider
   (numbered menus, y/n questions). Detection is a hint for buttons and alerts;
   it never sends anything by itself.

## Protocol additions (all optional fields; sealed as today)

Request (phone → Mac), new actions: `watch` (start streaming the selected tab),
`rows` (older rows before `index`), `close`, `rename` (`name`), `archive`,
`answer` (`text` = choice key), `notify` (`text` = APNs token hex, `name` =
`development|production`, empty text unregisters), `activity` (`text` = Live
Activity push token, `tabID`; empty text ends). `new` gains `worktree: Bool`.

Reply / event (Mac → phone): `event: true` marks an unsolicited frame; it has
`challenge` and `sequence: 0`. `RemoteState.Tab` gains `provider`, `providerName`,
`folder`, `canArchive`. `RemoteState` gains `prompt` and `mac` (computer name).
`screen` carries `{ gen, alt, first, end, rows: [{ i, t, w, s }], palette?, fg?, bg? }`
with `s` = style runs `[start, length, fg, bg, flags]` (fg/bg: -1 default,
0…255 ANSI, 16777216 + rgb true colour; flags: SwiftTerm `CharacterStyle` bits).
`rows` replies carry `screen` with older rows and the same `gen`.

Relay (host → relay): `{ pushToken, pushEnvironment }` registers the phone's
token for the room; `{ push: { data, thread } }` sends a sealed alert;
`{ push: { activity, state, event } }` updates a Live Activity.

## Commands

```
Mac:    swift test --no-parallel --scratch-path /tmp/sigil-build --filter Remote
        Scripts/verify.sh                       (CI runs this)
Relay:  cd Sidereal && npm test
Phone:  iOS/scripts/typecheck.sh && iOS/scripts/relay-e2e.sh && iOS/scripts/build.sh
Ship:   iOS/scripts/ship.sh; Scripts/deploy-sidereal.sh …; Scripts/install-latest.sh
```

## Project structure

- `Sources/SigilKit/Remote` — wire types, prompt detection, screen diffing (pure, tested).
- `Sources/SigilApp/Remote*.swift` — relay client, command adapter, event stream, push triggers.
- `Sidereal/server.mjs` — relay; `Sidereal/apns.mjs` — APNs client (Node `http2`, no dependency).
- `iOS/Sigil/Core` — protocol, screen model, styled text, credential list (compiled into tests).
- `iOS/Sigil/Shared` — types the app and its extensions share.
- `iOS/SigilNotifications` — Notification Service Extension. `iOS/SigilWidgets` — Live Activity.

## Testing strategy

Swift Testing for the Mac (table tests for prompt detection and screen diffs; a
relay round trip for events and push frames). Node tests for the relay (token
registration, push rate limit, APNs request shape against a fake HTTP/2 server).
The phone harness registers table tests for the screen model, styled text,
credential list migration, and an event round trip through the real relay.
Real-app proof: the isolated harness (test host + simulator) with screenshots.

## Boundaries

- Always: keep every limit (frame size, rates) explicit; keep the web client working.
- Ask first: nothing in scope needs a credential the owner alone holds; the APNs key is on this Mac.
- Never: write a key or token into the repository; log frame contents; change lock state from prose.

## Success criteria

1. With the app in the foreground, typing on the Mac appears on the phone within
   about 200 ms and the phone sends no periodic request.
2. Coloured CLI output shows in colour on the phone in both raw and readable modes.
3. Killing the app and relaunching shows the last screen before the socket opens.
4. Each session row shows its provider; close, rename and archive work from the
   phone and the Mac reflects them; a worktree session starts under `~/.sigil/worktrees`.
5. A numbered approval prompt shows Yes, No and 1…n buttons; tapping one answers it.
6. With the app closed, a finished turn and an approval prompt each raise a
   notification; a working session shows on the Lock Screen and updates.
7. Two Macs can be paired; the picker switches between them; a notification opens
   the right Mac and session.
