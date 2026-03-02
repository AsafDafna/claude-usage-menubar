# Claude Usage Menubar

A native macOS menu bar utility that shows your Claude API usage at a glance.

![macOS](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/license-MIT-green)

Two tiny horizontal bars in your menu bar — top bar is your 5-hour session usage, bottom bar is your 7-day weekly usage. Click for details.

## Install

### Homebrew

```bash
brew tap AsafDafna/tap
brew install claude-usage-menubar
```

Then launch from Applications or Spotlight.

### From Source

```bash
git clone https://github.com/AsafDafna/claude-usage-menubar.git
cd claude-usage-menubar
./build.sh
cp -R .build/ClaudeUsageMeter.app /Applications/
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## Prerequisites

[Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) must be installed and logged in:

```bash
claude /login
```

The app reads your OAuth credentials from `~/.claude/.credentials.json` or macOS Keychain.

## Usage

- **Menu bar icon**: Two horizontal bars showing 5h (top) and 7d (bottom) usage
- **Click**: Dropdown with exact percentages, progress bars, and reset countdowns
- **Refresh**: Manually update usage data
- **Log in...**: Opens Terminal with `claude /login` for re-authentication
- **Quit**: Exit the app

## Color Indicators

| Usage   | Color  |
|---------|--------|
| 0-50%   | Orange |
| 50-80%  | Amber  |
| 80-100% | Red    |

Usage auto-refreshes every 5 minutes. The app runs as a menu-bar-only utility (no dock icon).

## License

MIT
