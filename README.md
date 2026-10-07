# AeroSpace Companion

A practical [AeroSpace](https://github.com/nikitabobko/AeroSpace) setup for
macOS, with an AltTab-style window switcher and a compact window control panel.

[简体中文](README.zh-CN.md)

## Features

- `Option + Tab`: browse windows grouped by AeroSpace workspace.
- Empty AeroSpace workspaces appear as compact single rows in both Option-Tab
  and Command-Tab. Select one and release the held modifier, or click it, to switch
  without opening an app. Both shortcuts share the same list and ordering.
- `Option + Shift + Tab`: browse in reverse.
- `Command + Tab`: use the same window switcher instead of the macOS app switcher
  while AeroSpace is running (Accessibility and Input Monitoring permissions
  are required on first use).
- Mouse hover feedback without changing the keyboard selection; click to switch.
- While holding `Command`, press `Command + W` to close the selected window or
  `Command + Q` to quit its app without leaving the switcher.
  Rows show progress until the window disappears or the app finishes quitting.
  The footer confirms completion, explains unavailable actions, and flags requests
  still waiting after 12 seconds. Select a waiting item to check its app for a dialog.
  Closing items preserves the visible rows and panel position, including at the end
  of a scrolled list. Releasing Command after closing the last window does not reopen it.
- The first nine `Command + Tab` results show `Command + 1-9` keycaps for
  direct selection; release `Command` to switch as usual.
- Running apps without windows are included and can be reopened.
  Reopening warms the window catalog in the background. Very fast re-entry waits
  briefly for the new snapshot instead of flashing the stale windowless row;
  apps remain available while their windows are being registered.
- Workspaces show filled/outlined status dots and directional layout icons;
  compact display IDs (D1/D2/D3) stay at the right. Hover for full
  descriptions; custom labels are optional.
- Rows identify the current, fullscreen, floating, and hidden states. Dock
  unread counts, active microphone input, and audio output appear at the right
  edge; badges without a numeric count fall back to a red dot.
- Native settings for default/compact layout and empty workspace visibility,
  with preferences saved automatically.
- Default layout uses 34-point window rows, 32-point empty workspace rows, and
  28-point app icons; compact uses 32, 30, and 26 points respectively. The translucent
  panel follows the macOS light or dark appearance.
- `Option + Shift + M`: open Window Control for workspace moves, layouts,
  displays, arranging, and resizing. Number keys move the current window to
  workspace 1-10; hold `Shift` to move every window of the current app.
- Neutral numbered workspaces with opt-in developer app routing examples.
- No hardware-specific display assignments;
  quick-note and transient utility windows remain floating.
- Picture-in-Picture and mini-player windows stay floating on the current
  workspace.
- Persistent workspaces, directional display controls, focus wrapping, dedicated
  resize and arrange modes, and lazy mouse movement between displays.

## Settings

Press `Option + P` to search windows across all workspaces by app, title, workspace
number/label, or display name. Separate keywords with spaces. Use Up/Down to select,
Enter to switch, and Escape to cancel. The search stays open after releasing Option;
the existing Option-Tab and Command-Tab behavior is unchanged. The menu bar also
offers **Search windows…**.

Updates preserve personal configurations. Add this under `[mode.main.binding]`:

```toml
alt-p = 'exec-and-forget ~/.local/bin/aerospace-window-switcher-trigger --search'
```

See [named-monitors.toml](config/examples/named-monitors.toml) for a display-name
assignment example that keeps device roles when closing the lid or unplugging a
monitor. Check names with `aerospace list-monitors` and replace the existing table.

Click the AeroSpace Companion menu bar icon and choose **Settings…**. You can also
open the installed app, press `Command + ,` in the switcher, or run:

```sh
~/.local/bin/aerospace-window-switcher-trigger --settings
```

- **List layout**: Default uses 34-point window rows and 32-point empty workspace
  rows. Compact uses 32 and 30 points, with 14-point text, 26-point icons, smaller headers, and group gaps.
- **Show empty workspaces**: Include directly selectable empty workspaces, or show
  only occupied workspaces. Windowless apps in **OTHER APPS** are unaffected.

The initial settings are Default layout with empty workspaces shown. Changes are
saved automatically and applied the next time you open the switcher. Option-Tab
and Command-Tab share these settings. Closing Settings leaves the switcher running.

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

On first installation, the installer backs up the active AeroSpace config,
installs the included configuration, builds the native tools locally, and reloads
AeroSpace. Subsequent online updates preserve your config. Both Apple Silicon
and Intel Macs are supported.

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
Hover actions resolve the item under the pointer at key-down, including after a
close refresh. Command shortcuts and scrolling continue working when AeroSpace
focuses another app after a window closes.

## Update

After the first installation, update the tools while keeping your personal config:

```bash
~/.local/bin/aerospace-companion-update
```

To explicitly replace your config with the latest generic defaults (a backup is made),
run `~/.local/bin/aerospace-companion-update --with-config`.

## Workspaces and optional routing

The default uses numbered workspaces 1–10, tiles, and automatic initial
orientation, with no forced display assignments or app-to-workspace routing.
New windows are not moved to a numbered workspace by Companion rules.

Use `Option + Control + Tab` to move the current workspace to the next display.
AeroSpace does not guarantee exact placement restoration after every hotplug.
The installer does not rearrange macOS displays; follow
[AeroSpace's monitor arrangement guidance](https://nikitabobko.github.io/AeroSpace/guide#proper-monitor-arrangement)
to leave room for hidden windows.

For an opinionated developer setup, copy the entries from
[the optional routing example](config/examples/developer-routing.toml) into
your existing `on-window-detected` array. Do not create a second array.
It assigns media to 1, browsers to 2, editors to 3, terminals to 4,
development tools to 5, communication to 6, content to 7, and AI to 8;
9 and 10 remain manual. It contains no monitor bindings.

The example also starts with an app-agnostic guard rule:

```toml
{ if = 'test %{window-layout} = floating', run = 'layout floating' },
```

Because `on-window-detected` stops at the first matching rule, this keeps every
window AeroSpace already treats as floating (dialogs, quick-search bars, panels,
file pickers) on the workspace where it was opened, instead of dragging it to an
app's workspace. Place it after any rule that intentionally moves a floating
window (for example a picture-in-picture rule) and before the app routing rules.
No per-app exceptions are needed.

Labels are optional and independent of routing. For example:

```bash
defaults write io.github.tovifun.aerospace-companion.window-switcher \
  workspaceLabels -dict 1 Media 2 Browse 3 Code 4 Terminal 6 Chat
```

Restart the switcher after changing labels. Unspecified workspaces retain neutral
names. To reset, use `defaults delete io.github.tovifun.aerospace-companion.window-switcher workspaceLabels`.
Keep personal app and monitor rules in your active AeroSpace config; ordinary
updates will preserve them. Badge counts and audio status depend on information
available from the OS and applications.

An optional [laptop + ordered displays example](config/examples/laptop-ordered-monitors.toml)
puts workspace 1 on the laptop, 2–8 on the second display, and 9–10 on the
third display with fallback to the second, so a portrait third display holds two
workspaces. It requires the same left-to-right
arrangement at each location, not a particular macOS main display. It is not
installed by default; monitor numbers change when displays are rearranged or
the laptop is closed. Forced assignments disable manual whole-workspace moves.

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
