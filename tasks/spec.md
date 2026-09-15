# Spec: App dark themes

## Objective
Add a set of dark terminal themes based on popular apps' dark UIs, so a user can match Sigil to the rest of their desk. Existing themes stay. Success: each new theme is selectable, dark, WCAG-AA, and visually distinct.

## Tech Stack
Swift 6 / SwiftUI macOS 14. Themes live in `TerminalTheme`. Chrome still derives from `Palette`.

## Commands
Build: `swift build`
Test: `swift test --filter TerminalThemeTests --filter PaletteTests`
Lint: `swift format lint --configuration .swift-format --recursive --strict Sources Tests`
Dev: `Scripts/dev.sh`
Full gate: `Scripts/verify.sh`

## Project Structure
`Sources/SigilKit/Terminal/TerminalTheme.swift` — palettes
`Sources/SigilApp/Views/SettingsView.swift` — wrapping picker
`Tests/SigilKitTests/TerminalThemeTests.swift`
`Tests/SigilKitTests/PaletteTests.swift`

## Code Style
Match existing `HexPalette` + static `TerminalTheme` lets. Names are the app name. Accents keep the app hue; lift toward white until chrome AA passes.

## Testing Strategy
Swift Testing. Parameterize `TerminalTheme.all`. Assert unique names, unique grounds, all new themes dark, fg/bg AA, 16 unique ANSI colours, Palette AA (existing).

## Boundaries
- Always: keep Sigil Neon first; keep Grok Night/Day/Ember; keep chrome greys desaturated.
- Ask first: light themes, CLI TUI palettes beyond `GROK_THEME` fallback.
- Never: tint chrome; trademark logos; change default theme.

## Success Criteria
- 16 new dark themes inspired by GitHub, Linear, Notion, Discord, Slack, Spotify, VS Code, Cursor, X, Raycast, ChatGPT, Figma, macOS, Obsidian, Telegram, Twitch.
- Theme picker wraps; every swatch is reachable in Settings.
- `PaletteTests` and `TerminalThemeTests` pass for every theme.
- Default remains Sigil Neon.

## Open Questions
None. Accents that fail AA as chrome text are lifted, not used raw.
