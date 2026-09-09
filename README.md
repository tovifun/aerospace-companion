# AeroSpace Companion

A practical [AeroSpace](https://github.com/nikitabobko/AeroSpace) setup for
macOS, with an AltTab-style window switcher and a compact window control panel.

[简体中文](README.zh-CN.md)

## Features

- `Option + Tab`: browse windows grouped by AeroSpace workspace.
- `Option + Shift + Tab`: browse in reverse.
- `Command + Tab`: use the same window switcher instead of the macOS app switcher
  while AeroSpace is running (Accessibility and Input Monitoring permissions
  are required on first use).
- Mouse hover feedback without changing the keyboard selection; click to switch.
- While holding `Command`, press `Command + W` to close the selected window or
  `Command + Q` to quit its app without leaving the switcher.
- The first nine `Command + Tab` results show `Command + 1-9` keycaps for
  direct selection; release `Command` to switch as usual.
- Running apps without windows are included and can be reopened.
- Semantic workspace headers include the display, visibility, and window count.
- Rows identify the current, fullscreen, floating, and hidden states. Dock
  unread counts, active microphone input, and audio output appear at the right
  edge; badges without a numeric count fall back to a red dot.
- Compact translucent panel that follows the macOS light or dark appearance.
- `Option + Shift + M`: open Window Control for workspace moves, layouts,
  displays, arranging, and resizing. Number keys move the current window to
  workspace 1-10; hold `Shift` to move every window of the current app.
- Automatic app routing for development, browsers, communication, media, and
  design workspaces.
- General-purpose workspaces without hardware-specific display assignments;
  quick-note and transient utility windows remain floating.
- Picture-in-Picture and mini-player windows stay floating on the current
  workspace.
- Persistent workspaces, directional display controls, focus wrapping, dedicated
  resize and arrange modes, and lazy mouse movement between displays.

## Requirements

- macOS 13 or newer.
- Apple Command Line Tools: `xcode-select --install`.
- AeroSpace. The officially recommended Homebrew installation is:

```bash
brew install --cask nikitabobko/tap/aerospace
```

## Install

Install or update everything with one command:

```bash
curl -fsSL https://raw.githubusercontent.com/tovifun/aerospace-companion/main/scripts/install-online.sh | sh
```

The installer backs up the active AeroSpace config, installs the included
configuration, builds the native tools locally, and reloads AeroSpace. It
supports both Apple Silicon and Intel Macs.

For a manual checkout:

```bash
git clone https://github.com/tovifun/aerospace-companion.git
cd aerospace-companion
./scripts/install.sh --with-config
```

The built-in macOS Terminal is the default for `Option + Enter`, and each press
creates a new window. Choose another installed app at install time:

```bash
AEROSPACE_TERMINAL_APP=Ghostty ./scripts/install.sh --with-config
```

Without `--with-config`, the local installer updates only the companion tools.

### Optional community integrations

The installed configuration automatically starts JankyBorders when its
`borders` binary is available:

```bash
brew install FelixKratz/formulae/borders
```

For three-finger workspace switching that skips empty workspaces and wraps at
the ends, install
[aerospace-swipe](https://github.com/acsandmann/aerospace-swipe). It runs as a
separate launch agent and may request Accessibility permission:

```bash
curl -sSL https://raw.githubusercontent.com/acsandmann/aerospace-swipe/main/install.sh | bash
```

### First-run permissions

The installer opens a setup guide automatically. Enable both permissions for
AeroSpace Window Switcher:

1. **Accessibility** lets it replace the system `Command + Tab` behavior.
2. **Input Monitoring** lets it read the `Command`, `Shift`, and `Tab` keys.

The guide reports both permission states live. If the app is missing from the
Input Monitoring list, use **Reveal App** and add it with the `+` button. Choose
**Quit & Reopen** when macOS asks. This is a one-time setup; restarting AeroSpace
does not request the permissions again.

### Prefer the hovered item for Command actions

By default, `Command + W/Q` acts on the blue keyboard selection. To let the
gray item under the pointer take priority when one is hovered, run:

```bash
defaults write io.github.tovifun.aerospace-companion.window-switcher \
  hoveredItemActionPriority -bool true
```

Set the value to `false` to restore keyboard-selection priority. Restart the
window switcher after changing it.

## Update

After the first installation, update to the latest version and apply its config:

```bash
~/.local/bin/aerospace-companion-update
```

Updates back up the current config before replacing it.

## Workspace Routing

The default configuration uses tiles with automatic orientation and no forced
display assignments. AeroSpace chooses a new workspace's initial orientation
from the display's aspect ratio. App routing runs when windows are detected;
existing windows can be moved manually. No additional terminal is required.

The installer does not rearrange macOS displays.
Follow [AeroSpace's monitor arrangement guidance](https://nikitabobko.github.io/AeroSpace/guide#proper-monitor-arrangement)
to leave room for hidden windows. Badge counts and audio status depend on the
information available from the OS and applications.

| Workspace | Category | Apps |
| --- | --- | --- |
| `1` | Media and calls | Music, NetEase Music, Soda Music, Spotify, VLC, Bilibili, Douyin, TV, Tencent Meeting |
| `2` | Browsers and reference | Chrome, Safari, Edge, Dia, Vivaldi, ChatGPT Atlas, ego lite |
| `3` | Temporary and preview | No automatic routing |
| `4` | Codex and editors | Codex, Zed, Cursor, VS Code, Zcode, Xcode |
| `5` | Terminals and agents | Terminal, iTerm2, Ghostty, cmux, tty7, Otty, OpenCode |
| `6` | Git, databases, API, and diagnostics | Fork, DataGrip, Requestly, Activity Monitor, Console |
| `7` | Design and content | Figma, Eagle, RightFont, OBS, Screen Studio, Audacity, Writer, Typora, Clearly, Lettera, Notes, TextEdit |
| `8` | Communication and daily glance | Feishu, WeChat, WeCom, Mail, Calendar, Reminders |
| `9` | AI and research | Claude, WorkBuddy AI, Grok Bot |
| `10` | Extra workspace | No automatic routing; available for manual organization |

Workspaces use AeroSpace's default display placement. Use workspaces 1-10 on
a single display, or press `Option + Control + Tab` to move the current workspace
to the next display. Window Control also supports moving individual windows
between displays.

## Key Bindings

| Shortcut | Action |
| --- | --- |
| `Option + Tab` | Open the workspace-grouped window switcher |
| `Option + Shift + Tab` | Cycle backward |
| `Option + Shift + M` | Open Window Control |
| `Command + W` | Close the selected window while the switcher is open |
| `Command + Q` | Quit the selected window's app while the switcher is open |
| `Option + H/J/K/L` | Focus left/down/up/right, wrapping at workspace edges |
| `Option + Backtick` | Toggle the two most recently focused windows |
| `Option + Shift + H/J/K/L` | Move the focused window |
| `Option + 1-9/0` | Switch to workspace 1-10 |
| `Option + Shift + 1-9/0` | Move the window to workspace 1-10 and follow it |
| `Option + Left/Right` | Cycle non-empty workspaces on the focused display |
| `Option + /` | Toggle tiles and accordion |
| `Option + Shift + /` | Change tile orientation |
| `Option + Shift + Space` | Toggle floating and tiling |
| `Option + F` | Toggle fullscreen |
| `Option + R` | Enter resize mode |
| `Option + B` | Switch to the previous workspace |
| `Option + S` | Enter arrange mode |
| `Option + Control + H/J/K/L` | Focus another monitor |
| `Option + Control + Shift + H/J/K/L` | Move the window to another monitor |
| `Option + Control + Tab` | Move the current workspace to the next display |

In arrange mode, use `H/J/K/L` to swap windows,
`Shift + H/J/K/L` to group windows, `R` to flatten the workspace, and `Esc` to
exit.

In resize mode, use `H/J/K/L` for 50-point width/height changes,
`Shift + H/J/K/L` for 10-point changes, and `Enter` or `Esc` to exit.

Window Control accepts `1-9/0` to move the current window, or
`Shift + 1-9/0` to move every window of the current app. Use `F` for
floating/tiling, `M` for fullscreen, `T` for tiles/accordion, `O` for
orientation, `B` to balance, `R` to reset, arrow keys to move between
displays, `A` for its visual arrange mode, and `Z` for its visual resize mode.

## Uninstall

Remove the tools and restore the config that was backed up during installation:

```bash
aerospace-companion-uninstall --restore-config
```

Omit `--restore-config` to leave the current AeroSpace configuration untouched.

## Development

```bash
make build
make test
```

The window switcher is a native AppKit accessory app. No third-party runtime
or package dependency is required.

## License

MIT
