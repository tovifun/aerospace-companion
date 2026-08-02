# AeroSpace Companion

A practical [AeroSpace](https://github.com/nikitabobko/AeroSpace) setup for
macOS, with an AltTab-style window switcher and a workflow for moving every
window of the focused app to another workspace.

[简体中文](README.zh-CN.md)

## Features

- `Option + Tab`: browse windows grouped by AeroSpace workspace.
- `Option + Shift + Tab`: browse in reverse.
- Mouse hover feedback without changing the keyboard selection; click to switch.
- Running apps without windows are included and can be reopened.
- Compact translucent panel that follows the macOS light or dark appearance.
- `Option + Shift + M`: move every window of the focused app to workspace 1-9.
- Automatic app routing for development, browsers, communication, media, and
  design workspaces.
- Floating rules for writing tools, utilities, and the dedicated Feishu media
  helper process.
- Persistent workspaces, dual-monitor assignments, and an arrange mode.

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

Ghostty is the default terminal for `Option + Enter`. Choose another app at
install time:

```bash
AEROSPACE_TERMINAL_APP=Kitty ./scripts/install.sh --with-config
```

Without `--with-config`, the local installer updates only the companion tools.

## Update

After the first installation, update to the latest version and apply its config:

```bash
~/.local/bin/aerospace-companion-update
```

Updates back up the current config before replacing it.

## Workspace Routing

| Workspace | Category | Apps |
| --- | --- | --- |
| `1` | Development | Codex, Claude, Zed, Cursor, VS Code, Xcode, Ghostty, DataGrip, Fork, OpenCode |
| `2` | Browsers | Chrome, Safari, Edge, Dia, Vivaldi, ChatGPT Atlas |
| `3` | Communication | Feishu, WeChat, WeCom, Tencent Meeting, Mail |
| `4` | Media | Music, NetEase Music, Soda Music, VLC, Bilibili, Douyin, TV |
| `5` | Design | Figma, Eagle, RightFont, OBS, Screen Studio, Audacity |

Workspaces 1-2 prefer the main display. Workspaces 3-9 prefer the built-in
display and fall back to the main display. Writing and task apps stay on the
current workspace as floating windows.

## Key Bindings

| Shortcut | Action |
| --- | --- |
| `Option + Tab` | Open the workspace-grouped window switcher |
| `Option + Shift + Tab` | Cycle backward |
| `Option + Shift + M` | Move all windows of the focused app |
| `Option + H/J/K/L` | Focus left/down/up/right |
| `Option + Shift + H/J/K/L` | Move the focused window |
| `Option + 1-9` | Switch workspace |
| `Option + Shift + 1-9` | Move the window and follow it |
| `Option + /` | Toggle tiles and accordion |
| `Option + Shift + /` | Change tile orientation |
| `Option + Shift + Space` | Toggle floating and tiling |
| `Option + F` | Toggle fullscreen |
| `Option + B` | Switch to the previous workspace |
| `Option + S` | Enter arrange mode |
| `Option + Control + H/J/K/L` | Focus another monitor |
| `Option + Control + Shift + H/J/K/L` | Move the window to another monitor |

In arrange mode, use `H/J/K/L` to swap windows,
`Shift + H/J/K/L` to group windows, `R` to flatten the workspace, and `Esc` to
exit.

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
