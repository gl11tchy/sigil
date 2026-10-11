Shipped in [#28](https://github.com/gl11tchy-team/sigil/pull/28); kept for history. Later delivery evidence is indexed in [task history](README.md).

# Spec: Phone remote that you can actually use

## Objective
Make Sidereal work as a one-thumb iPhone companion: readable output, one composer, photos and files from the phone. Success: the live Grok 4.6 idle screen is a short status plus the phone composer, and a photo from the library lands in the Mac session as a path.

## Tech Stack
Existing Sidereal PWA + encrypted relay; Swift 6 RemoteCommands / RemoteSession / TerminalDrop. No new dependencies.

## Commands
Companion: `cd Sidereal && npm test && npm run test:browser`
Native: `swift test --no-parallel --filter Remote`
Full: `Scripts/verify.sh`

## Project Structure
`Sidereal/public/output.mjs` — readable snapshot
`Sidereal/public/{index.html,style.css,app.mjs,sw.js}` — phone UI
`Sources/SigilKit/Remote/RemoteSession.swift` — file-chunk size limits
`Sources/SigilKit/Remote/RemoteUpload.swift` — chunk assembly
`Sources/SigilKit/Terminal/TerminalDrop.swift` — write uploaded bytes
`Sources/SigilApp/RemoteCommands.swift` — `file` action
Matching tests under `Sidereal/test` and `Tests/`

## Code Style
Match existing small Codable requests, bounded frames, and `TerminalDrop` path paste.

## Testing Strategy
Failing unit tests first for the live Grok 4.6 footer (from the phone screenshot) and for chunk assembly. Playwright covers attach → chip → send. Native tests paste a PNG through `file` into an isolated PTY.

## Boundaries
- Always: keep the relay ciphertext-only; cap a remote file at 4 MB; magic-byte images; sanitize names; write only to the drop cache; paste a path, never execute.
- Ask first: raising the 64 KB plaintext ceiling; exposing Mac filesystem reads.
- Never: log file bytes; put uploads in IndexedDB; bypass pairing.

## Success Criteria
- Idle Grok 4.6 composer and space-padded TUI rows do not appear in readable mode.
- Mac-side drafts and unknown prompts stay visible.
- Phone can attach photos/files, see chips, and send them; Mac writes the file and pastes its path.
- Attach and send stay 44px targets at 320–430px. Composer stays above the iOS keyboard.
- Raw terminal toggle still shows the lossless snapshot.

## Open Questions
None. Photos compress on the phone to JPEG. Other files send as-is up to 4 MB.
