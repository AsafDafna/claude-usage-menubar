# Claude Usage Menu Bar Meter — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a native macOS menu bar utility that shows Claude API usage as two stacked horizontal bars with a detail dropdown.

**Architecture:** Single Swift file compiled with `swiftc -framework Cocoa -framework Security`. Uses `NSStatusItem` for the menu bar, `URLSession` for API calls, and macOS Keychain/file system for credentials. No Xcode project, no external dependencies.

**Tech Stack:** Swift 6, AppKit (Cocoa), Foundation, Security framework

---

### Task 1: Scaffold the app with a static menu bar icon

**Files:**
- Create: `Sources/main.swift`
- Create: `build.sh`

**Step 1: Create build script**

```bash
#!/bin/bash
set -e
mkdir -p .build
swiftc Sources/main.swift \
  -o .build/ClaudeUsageMeter \
  -framework Cocoa \
  -framework Security \
  -swift-version 6
echo "Built: .build/ClaudeUsageMeter"
```

**Step 2: Create minimal menu bar app**

Write `Sources/main.swift` with:
- An `NSApplication` setup (no storyboard/nib)
- An `AppDelegate` class that creates an `NSStatusItem`
- A static placeholder icon (two gray bars) drawn via `NSImage(size:flipped:drawingHandler:)`
- A basic `NSMenu` with just "Quit" item
- `app.run()` to start the run loop

The icon drawing function:
- Image size: 30x22 (standard menu bar icon height is 22)
- Two horizontal bars: top at y=4, bottom at y=13, each 4px tall
- Full width gray tracks (hex `#3a3530`)
- This is just static for now — no usage data yet

**Step 3: Build and run**

Run: `chmod +x build.sh && ./build.sh && .build/ClaudeUsageMeter`
Expected: A small gray double-bar icon appears in the menu bar. Clicking shows a menu with "Quit".

**Step 4: Commit**

```bash
git add Sources/main.swift build.sh
git commit -m "feat: scaffold menu bar app with static icon"
```

---

### Task 2: Implement credential reading

**Files:**
- Modify: `Sources/main.swift`

**Step 1: Add credential structs and reading logic**

Add to `main.swift`:
- `struct OAuthCredentials` with `accessToken`, `refreshToken`, `expiresAt` (milliseconds)
- `struct CredentialFile: Codable` matching `{"claudeAiOauth": {...}}`
- `class CredentialManager` with:
  - `func readCredentials() -> OAuthCredentials?` that tries file first, then Keychain
  - `private func readFromFile() -> OAuthCredentials?` — reads `~/.claude/.credentials.json`, decodes JSON
  - `private func readFromKeychain() -> OAuthCredentials?` — uses `SecItemCopyMatching` with service `"Claude Code-credentials"`, parses the JSON string from the password data
  - `var isExpired: Bool` computed from `expiresAt` vs `Date().timeIntervalSince1970 * 1000`

**Step 2: Build and test manually**

Run: `./build.sh && .build/ClaudeUsageMeter`
Expected: App starts. Add a temporary `print()` in `readCredentials()` to verify it finds credentials. Check terminal output shows the token was found (just print "Found credentials: true/false", never print actual tokens).

**Step 3: Commit**

```bash
git add Sources/main.swift
git commit -m "feat: add credential reading from file and Keychain"
```

---

### Task 3: Implement API client (token refresh + usage fetch)

**Files:**
- Modify: `Sources/main.swift`

**Step 1: Add API client**

Add to `main.swift`:
- `struct UsageBucket: Codable` with `utilization: Double` and `resets_at: String` (using `CodingKeys` for snake_case)
- `struct UsageResponse: Codable` with `five_hour: UsageBucket?` and `seven_day: UsageBucket?` (using `CodingKeys`)
- `class APIClient` with:
  - `let credentialManager: CredentialManager`
  - `func fetchUsage(completion: @escaping (Result<UsageResponse, Error>) -> Void)` that:
    1. Reads credentials, returns error if none
    2. Checks if expired → calls `refreshToken()` first
    3. Makes GET to `https://api.anthropic.com/api/oauth/usage` with headers:
       - `Authorization: Bearer <token>`
       - `Content-Type: application/json`
       - `anthropic-beta: oauth-2025-04-20`
    4. On 401/403 → tries refresh once, retries
    5. Decodes `UsageResponse`
  - `private func refreshToken(_ refreshToken: String, completion: ...)` that:
    1. POSTs to `https://platform.claude.com/v1/oauth/token` with JSON body `{"grant_type": "refresh_token", "refresh_token": "...", "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers"}`
    2. Parses response for new `access_token`, `refresh_token`, `expires_in`
    3. Persists updated credentials back to file (and Keychain on macOS)
  - `private func persistCredentials(_ creds: OAuthCredentials)` — writes back to `~/.claude/.credentials.json`

**Step 2: Build and test manually**

Run: `./build.sh && .build/ClaudeUsageMeter`
Expected: Add a temporary call to `fetchUsage` in `applicationDidFinishLaunching`. Terminal should print the usage response (utilization numbers). If credentials are expired, it should refresh and then fetch.

**Step 3: Commit**

```bash
git add Sources/main.swift
git commit -m "feat: add API client with token refresh and usage fetch"
```

---

### Task 4: Dynamic icon rendering based on usage data

**Files:**
- Modify: `Sources/main.swift`

**Step 1: Add dynamic icon drawing**

Add to `main.swift`:
- `func colorForPercent(_ pct: Double) -> NSColor` returning:
  - `#d9773c` (orange) for 0-50%
  - `#e8a838` (amber) for 50-80%
  - `#e74c3c` (red) for 80-100%
- `func drawMenuBarIcon(fiveHour: Double, sevenDay: Double) -> NSImage` that:
  - Creates `NSImage(size: NSSize(width: 30, height: 22), flipped: false)`
  - Draws two horizontal bars at y=5 and y=13, each 4px tall, total track width 24px (centered)
  - Track background: `#3a3530`
  - Filled portion: `colorForPercent` based on each bar's percentage
  - Rounded rect ends (cornerRadius 2)
  - Sets `isTemplate = false` so colors render correctly

**Step 2: Wire up icon updates**

- Store `var currentUsage: UsageResponse?` on the app delegate
- After successful `fetchUsage`, update `currentUsage` and call `updateIcon()`
- `updateIcon()` redraws the status item image from current data

**Step 3: Build and test**

Run: `./build.sh && .build/ClaudeUsageMeter`
Expected: After a brief delay (~1s for the API call), the gray bars change to colored bars reflecting actual usage percentages.

**Step 4: Commit**

```bash
git add Sources/main.swift
git commit -m "feat: render dynamic colored bars based on usage data"
```

---

### Task 5: Add detail dropdown menu

**Files:**
- Modify: `Sources/main.swift`

**Step 1: Create custom menu item views**

Add to `main.swift`:
- `class UsageMenuItemView: NSView` that renders:
  - Label (e.g. "Session (5h)") left-aligned, percentage right-aligned, both bold
  - A horizontal progress bar below: track `#3a3530`, fill colored by percentage
  - Reset countdown text below the bar (e.g. "Resets in 2h 14m"), gray, smaller font
  - Total height ~55px, width 250px
- `func formatResetTime(_ isoString: String) -> String` that:
  - Parses ISO 8601 date
  - Computes delta from now
  - Returns "Resets in Xd Yh" or "Resets in Xh Ym" or "Resets in Xm"

**Step 2: Build the menu**

Replace the simple "Quit" menu with:
- `NSMenuItem` with custom `UsageMenuItemView` for 5h session
- `NSMenuItem` with custom `UsageMenuItemView` for 7d weekly
- `NSMenuItem.separator()`
- "Refresh" item → calls `fetchUsage()`
- "Log in..." item → spawns `claude /login` via `Process`
- "Quit" item → `NSApp.terminate(nil)`

Update both menu item views whenever new usage data arrives.

**Step 3: Build and test**

Run: `./build.sh && .build/ClaudeUsageMeter`
Expected: Clicking the menu bar icon shows the dropdown with two usage sections, progress bars, reset countdowns, and action items.

**Step 4: Commit**

```bash
git add Sources/main.swift
git commit -m "feat: add detail dropdown with usage bars and reset times"
```

---

### Task 6: Add polling timer and login flow

**Files:**
- Modify: `Sources/main.swift`

**Step 1: Add polling**

- In `applicationDidFinishLaunching`:
  - Call `fetchUsage()` immediately
  - Start a `Timer.scheduledTimer` that calls `fetchUsage()` every 300 seconds (5 min)

**Step 2: Add login action**

- "Log in..." menu item handler:
  - Finds `claude` binary via `/usr/bin/env which claude` or common paths
  - Spawns `Process()` with `/bin/zsh -c "claude /login"`
  - After process exits, triggers a `fetchUsage()` to pick up new credentials

**Step 3: Add error handling in the icon**

- If fetch fails or no credentials: show two gray bars (the empty state)
- Optionally show a small "!" or tooltip on the status item indicating the error

**Step 4: Build and test**

Run: `./build.sh && .build/ClaudeUsageMeter`
Expected: App fetches on launch, then every 5 minutes. "Log in..." opens a terminal with `claude /login`. After login completes, usage refreshes.

**Step 5: Commit**

```bash
git add Sources/main.swift
git commit -m "feat: add 5-minute polling and login flow"
```

---

### Task 7: Create .app bundle and install script

**Files:**
- Modify: `build.sh`

**Step 1: Update build script to create .app bundle**

Update `build.sh` to:
1. Compile the binary as before
2. Create `.build/ClaudeUsageMeter.app/Contents/MacOS/` directory
3. Copy binary into it
4. Write `Info.plist` with:
   - `LSUIElement: true` (no dock icon — menu bar only)
   - `CFBundleIdentifier: com.claude.usage-meter`
   - `CFBundleName: ClaudeUsageMeter`
5. Optionally generate an icon using `sips` or include a static `.icns`
6. Print instructions: "cp -R .build/ClaudeUsageMeter.app /Applications/"

**Step 2: Build and test**

Run: `./build.sh && open .build/ClaudeUsageMeter.app`
Expected: App launches from the .app bundle, no dock icon visible, menu bar icon appears.

**Step 3: Install and verify**

Run: `cp -R .build/ClaudeUsageMeter.app /Applications/ && open /Applications/ClaudeUsageMeter.app`
Expected: Launches from Applications folder correctly.

**Step 4: Commit**

```bash
git add build.sh
git commit -m "feat: create .app bundle with LSUIElement for menu-bar-only mode"
```

---

### Task 8: Final polish and testing

**Files:**
- Modify: `Sources/main.swift`

**Step 1: Handle edge cases**

- No credentials file and no Keychain entry → show gray bars, "Log in..." is prominent
- Token refresh fails → show gray bars, log error
- API returns unexpected JSON → handle gracefully
- Network timeout → keep showing last known data

**Step 2: Test full flow**

1. Launch app — icon appears in menu bar
2. Bars reflect actual usage
3. Click → dropdown shows correct percentages and reset times
4. "Refresh" works
5. "Quit" works
6. Wait 5 minutes — bars update automatically
7. Kill app, relaunch — works again

**Step 3: Commit**

```bash
git add Sources/main.swift
git commit -m "feat: add error handling and edge case polish"
```
