# Claude Usage Menu Bar Meter — Design

## Goal

A native macOS menu bar utility that displays Claude API usage as two stacked horizontal bars (5h session and 7d weekly), with a click-to-expand dropdown showing detailed usage info.

## Menu Bar Icon

- ~22px tall, ~30px wide, rendered as an `NSImage` on `NSStatusItem`
- Two stacked horizontal bars:
  - Top bar: 5h session utilization
  - Bottom bar: 7d weekly utilization
- Bar width proportional to usage percentage
- Color: orange (0-50%), amber (50-80%), red (80-100%)
- Empty portion: dark gray track

## Click Dropdown

Native `NSMenu` with custom views showing:
- **Session (5h)**: percentage, progress bar, reset countdown
- **Weekly (7d)**: percentage, progress bar, reset countdown
- Separator
- **Refresh**: manually trigger a fetch
- **Log in...**: spawns `claude /login`
- **Quit**: exits the app

## Architecture

- **Language**: Swift, compiled with `swiftc` (no Xcode project)
- **Menu bar**: `NSStatusItem` with dynamically drawn `NSImage`
- **Networking**: `URLSession` for API calls
- **Polling**: `Timer` every 5 minutes (default)
- **Credential sources** (in order):
  1. `~/.claude/.credentials.json` file
  2. macOS Keychain (service: `"Claude Code-credentials"`)
- **Token refresh**: `POST https://platform.claude.com/v1/oauth/token` with refresh token
- **Usage API**: `GET https://api.anthropic.com/api/oauth/usage` with bearer token and `anthropic-beta: oauth-2025-04-20` header

## API Response Structure

```json
{
  "five_hour": {
    "utilization": 42.0,
    "resets_at": "2026-03-02T15:00:00Z"
  },
  "seven_day": {
    "utilization": 18.0,
    "resets_at": "2026-03-07T00:00:00Z"
  }
}
```

## Credential File Format

```json
{
  "claudeAiOauth": {
    "accessToken": "...",
    "refreshToken": "...",
    "expiresAt": 1709400000000
  }
}
```

## Build & Install

- Compile: `swiftc -o ClaudeUsageMeter main.swift -framework Cocoa`
- Optionally wrap in `.app` bundle for `/Applications/` install
- No external dependencies

## Color Scheme

| Usage Range | Color  | Hex       |
|-------------|--------|-----------|
| 0-50%       | Orange | `#d9773c` |
| 50-80%      | Amber  | `#e8a838` |
| 80-100%     | Red    | `#e74c3c` |
| Track       | Gray   | `#3a3530` |
