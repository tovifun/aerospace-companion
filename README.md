# AeroSpace Companion

A practical [AeroSpace](https://github.com/nikitabobko/AeroSpace) setup for
macOS, with an AltTab-style window switcher and a workflow for moving every
window of the focused app to another workspace.

[简体中文](README.zh-CN.md)

## Features

- `Option + Tab`: browse windows grouped by AeroSpace workspace.
- `Option + Shift + Tab`: browse in reverse.
- Mouse hover and click selection.
- Running apps without windows are included and can be reopened.
- Compact translucent panel that follows the macOS light or dark appearance.
- `Option + Shift + M`: move every window of the focused app to workspace 1-9.
- A complete, low-gap AeroSpace configuration for daily use.

## Requirements

- macOS 13 or newer.
- Apple Command Line Tools: `xcode-select --install`.
- AeroSpace. The officially recommended Homebrew installation is:

```bash
brew install --cask nikitabobko/tap/aerospace
```

## Install

```bash
git clone https://github.com/tovifun/aerospace-companion.git
cd aerospace-companion
./scripts/install.sh --with-config
```

`--with-config` backs up the existing AeroSpace config before installing the
included configuration. Without it, only the companion tools are installed.

Ghostty is the default terminal for `Option + Enter`. Choose another app at
install time:

```bash
AEROSPACE_TERMINAL_APP=Kitty ./scripts/install.sh --with-config
```

The installer builds the Swift tools locally and installs them under
`~/.local`. It supports both Apple Silicon and Intel Macs.

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
