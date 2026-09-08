# QR remote control

## Objective and scope

Pair a phone from Sigil Settings and control this Mac using the Sidereal PWA.
The default is internet access through an HTTPS/WebSocket relay, not an exposed
Mac listening port. Sigil must stay open and the Mac must stay awake.

The companion can list and select open tabs, read bounded terminal text, send
text and terminal keys, and create a session in the current folder. It does not
expose arbitrary file access, shell launch configuration, or the local MCP socket.
Remote input has the same authority as typing in an open Grok session.

## Contract and security

- Remote control starts off. Starting it requires an HTTPS companion URL.
- The Mac makes outbound connections only. The included Node relay serves the PWA.
- QR pairing uses a random 256-bit secret in the URL fragment, never a query.
- Pairing expires after five minutes and is consumed once. A phone supplies a
  different 256-bit device key through the encrypted pairing exchange.
- Commands and responses use AES-256-GCM (96-bit random nonce, 128-bit tag).
  Direction is authenticated. Each connection has a fresh Mac-generated challenge;
  each request has a strictly increasing sequence. No command retries or offline queue.
- The Mac keeps device credentials in memory. The phone stores a non-extractable
  CryptoKey in IndexedDB. Disconnecting in Sigil or quitting revokes access.
- The relay routes bounded ciphertext, not terminal contents or encryption keys.
  The web host is trusted to serve the correct client code (as with any web app).
- Frames, peers, rooms, request rates and send buffers have explicit limits.
- No content or credentials in logs, service-worker caches, or repository files.

## Implementation

Swift 6 / macOS 14; CryptoKit, Foundation URLSession, existing SwiftTerm controller.
`Sources/SigilKit/Remote` contains the wire protocol and pairing checks.
`Sources/SigilApp` contains the outbound connection, command adapter and settings UI.
`Sidereal` contains the Node relay, dependency lockfile, static PWA and Node tests.
No change to unrelated tabs, themes, panel behavior, or tab messaging.

Use existing main-actor model methods and small Codable value types:

```swift
struct RemoteRequest: Codable, Sendable {
    let challenge: String
    let sequence: Int
    let action: String
    let tabID: String?
    let text: String?
}
```

## Verification and boundaries

Build/tests: `swift test --no-parallel`.
Full native gate: `Scripts/verify.sh`.
Companion: `cd Sidereal && npm ci && npm test && npm audit --omit=dev`.
Test unauthenticated, expired, reused, tampered, reflected and replayed messages;
revocation; transport limits; and real terminal input/output using an isolated fixture.
Browser-check the phone-sized companion and native QR settings with synthetic data.
Never operate existing personal sessions during QA. Never log pairing secrets.
Hosting needs a real HTTPS deployment; local tests do not prove cellular/iPhone access.

## References

- [CryptoKit sealed boxes](https://developer.apple.com/documentation/cryptokit/aes/gcm/sealedbox)
- [Web Crypto AES-GCM parameters](https://developer.mozilla.org/en-US/docs/Web/API/AesGcmParams)
- [Secure contexts](https://developer.mozilla.org/en-US/docs/Web/Security/Defenses/Secure_Contexts)
- [ws server limits](https://github.com/websockets/ws/blob/master/doc/ws.md)

## Local evidence

- `Scripts/verify.sh`: native tests, companion tests/audit, shell checks, formatting,
  signed debug bundle and isolated smoke launch passed.
- Native integration sends encrypted input through the real Node relay into an
  isolated PTY, receives its output encrypted, and verifies stop closes the phone.
- Browser checked at 390 × 844: QR-fragment pairing, sending, session creation and
  reload/reconnect. Browser interaction used a synthetic encrypted host, not personal sessions.
- Native Settings checked in a separate temporary app identity; the entire QR fits
  without scrolling. Vision also decoded the generated QR payload in a unit test.
- Independent review found and fixed replay-reset ownership, relay reconnect grace,
  unauthorized peer eviction, connection-bound Send, and terminal input-mode handling.
- Not yet verified: public HTTPS deployment, physical camera scan, cellular access,
  or iOS Home Screen installation. These need the hosted relay and a physical phone.
