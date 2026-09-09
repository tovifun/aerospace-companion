#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(dirname "$script_dir")

sh -n "$root_dir/scripts/build.sh"
sh -n "$root_dir/scripts/install.sh"
sh -n "$root_dir/scripts/install-online.sh"
sh -n "$root_dir/scripts/uninstall.sh"
sh -n "$root_dir/scripts/aerospace-show-ambient"
sh -n "$root_dir/scripts/aerospace-window-switcher-trigger"
sh -n "$root_dir/scripts/aerospace-open-terminal-window"
sh -n "$root_dir/scripts/aerospace-start-borders"
zsh -n "$root_dir/scripts/aerospace-move-focused-app-to-workspace"
plutil -lint "$root_dir/resources/Info.plist"

grep -q 'loadWindows(presentErrors: false)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'DispatchQueue.global(qos: .userInteractive).async' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'switchingTo: focusedWorkspace == window.workspace' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'let hasCachedItems = !orderedItems.isEmpty' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'self.warmIconCache()' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'let dockBadgeSnapshot = DockBadgeClient.currentSnapshot()' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'attribute("AXStatusLabel", from: element)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'subrole == "AXApplicationDockItem"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'badge.layer?.backgroundColor = NSColor.systemRed.cgColor' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'rawLabel.compactMap(\\.wholeNumberValue)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'let audioActivitySnapshot = AudioActivityClient.currentSnapshot()' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'kAudioHardwarePropertyProcessObjectList' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'kAudioProcessPropertyIsRunningOutput' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'kAudioProcessPropertyIsRunningInput' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'systemSymbolName: "mic.fill"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'systemSymbolName: "speaker.wave.2.fill"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q -- '-framework CoreAudio' \
    "$root_dir/scripts/build.sh"
grep -q 'return excludingStaleUntitledWindows(windows)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'CGWindowListCopyWindowInfo' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'liveWindowOwners\[window.windowID\] == window.appPID' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'if isRefreshing || orderedItems.isEmpty' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'globalMouseMonitor = NSEvent.addGlobalMonitorForEvents' \
    "$root_dir/src/window-switcher/main.swift"
grep -q '!panel.frame.contains(NSEvent.mouseLocation)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'maximumPanelHeight: CGFloat = 960' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'scrollView.hasVerticalScroller = false' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'OverflowFadingScrollView' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'canScrollBelow ? transparent : opaque' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'localMagnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'globalMagnifyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'scrollSwitcher(byMagnification: event.magnification)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'currentOrigin.y - magnification \* 800' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'panel.frame.contains(mouseLocation)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'scrollView.scrollWheel(with: event)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'CGEventType.scrollWheel.rawValue' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'scrollEventCopy.flags.subtracting(.maskCommand)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'let scrollEvent = NSEvent(cgEvent: scrollEventCopy)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'scrollView.scrollWheel(with: scrollEvent)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'CGEvent.tapCreate' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'tracking: .command' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case kVK_ANSI_W:' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case kVK_ANSI_Q:' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'commandSelectionShortcutNumber(for: item)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q '"⌘\\(number)"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'run(\["close", "--window-id", String(windowID)\])' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'runningApplication.terminate()' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case appPID = "app-pid"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case isFullscreen = "window-is-fullscreen"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case windowLayout = "window-layout"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case workspaceIsVisible = "workspace-is-visible"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case monitorName = "monitor-name"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case "4": role = localized("CODE & EDITORS", "Codex 与编辑器")' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case "8": role = localized("COMMUNICATION", "沟通")' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case "10": role = localized("AMBIENT", "氛围空屏")' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'parts.append(localized("CURRENT", "当前"))' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'window?.windowLayout == "floating"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'NSRunningApplication(processIdentifier: processIdentifier)?.isHidden' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'AXIsProcessTrustedWithOptions' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'CGRequestListenEventAccess' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'PermissionGuideWindowController' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'Privacy_Accessibility' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'Privacy_ListenEvent' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'activateFileViewerSelecting' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'First run: follow the permission guide' \
    "$root_dir/scripts/install.sh"
initial_selection_matches=$(grep -c \
    'initialIndex = currentIndex + pendingCycleDelta' \
    "$root_dir/src/window-switcher/main.swift")
test "$initial_selection_matches" -eq 2
if grep -q 'currentIndex + launchDirection' \
    "$root_dir/src/window-switcher/main.swift"; then
    printf 'Initial selection must stay on the currently focused item.\n' >&2
    exit 1
fi
grep -q 'static let hoveredItemActionPriorityKey = "hoveredItemActionPriority"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'row.onHoverChanged = ' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'let target = commandActionTarget' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'DispatchSource.makeSignalSource(signal: SIGURG, queue: .main)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'prepareWindowControlPanel()' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'private final class WindowControlPanelController' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'for rowRange in \[1\.\.\.5, 6\.\.\.10\]' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case moveApplicationToWorkspace(String)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'self.updateWindowControlPanelIfVisible()' \
    "$root_dir/src/window-switcher/main.swift"
grep -q '"1–0 当前窗口   ⇧1–0 当前 App 全部窗口' \
    "$root_dir/src/window-switcher/main.swift"
grep -q '"move-node-to-monitor", "--focus-follows-window"' \
    "$root_dir/src/window-switcher/main.swift"
grep -q '"flatten-workspace-tree", "--workspace", request.targetWorkspace' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'case "a":' "$root_dir/src/window-switcher/main.swift"
grep -q 'case "z":' "$root_dir/src/window-switcher/main.swift"
grep -q 'target == "0" ? "10"' "$root_dir/src/workspace-prompt/main.swift"
grep -q '/bin/kill -URG "$pid"' \
    "$root_dir/scripts/aerospace-move-focused-app-to-workspace"
grep -q 'pgrep -f "$legacy_binary"' "$root_dir/scripts/install.sh"
grep -q '^\[workspace-to-monitor-force-assignment\]' \
    "$root_dir/config/aerospace.toml"
grep -q "1 = 'built-in'" \
    "$root_dir/config/aerospace.toml"
grep -q "4 = 'dell'" \
    "$root_dir/config/aerospace.toml"
grep -q "7 = 'dell'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "10 = ['^Portrait$', '^$', 'dell', 'built-in']" \
    "$root_dir/config/aerospace.toml"
grep -Fq "layout --workspace 4 --root h_tiles" \
    "$root_dir/config/aerospace.toml"
grep -Fq "layout --workspace 10 --root v_accordion" \
    "$root_dir/config/aerospace.toml"
grep -Fq "com.google.Chrome', run = 'move-node-to-workspace 2'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "com.citrolabs.ego.lite', run = 'move-node-to-workspace 2'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "com.github.tty7', run = 'move-node-to-workspace 5'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "io.appmakes.otty', run = 'move-node-to-workspace 5'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "com.DanPristupov.Fork', run = 'move-node-to-workspace 6'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "com.electron.lark', run = 'move-node-to-workspace 8'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "com.spotify.client', run = 'move-node-to-workspace 1'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "com.figma.Desktop', run = 'move-node-to-workspace 7'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "com.anysphere.sand', run = 'move-node-to-workspace 9'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "abnerworks.Typora', run = 'move-node-to-workspace 7'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "com.apple.ActivityMonitor', run = 'move-node-to-workspace 6'" \
    "$root_dir/config/aerospace.toml"
grep -Fq "com.apple.iCal', run = 'move-node-to-workspace 8'" \
    "$root_dir/config/aerospace.toml"
grep -q "alt-ctrl-2 = 'focus-monitor dell'" \
    "$root_dir/config/aerospace.toml"
grep -q "alt-ctrl-1 = 'focus-monitor built-in'" \
    "$root_dir/config/aerospace.toml"
grep -q "alt-ctrl-3 = 'focus-monitor 3'" \
    "$root_dir/config/aerospace.toml"
grep -q "on-focused-monitor-changed = \['move-mouse monitor-lazy-center'\]" \
    "$root_dir/config/aerospace.toml"
grep -q "alt-backtick = 'focus-back-and-forth || workspace-back-and-forth'" \
    "$root_dir/config/aerospace.toml"
grep -q "alt-r = 'mode resize'" \
    "$root_dir/config/aerospace.toml"
grep -q '^\[mode.resize.binding\]' \
    "$root_dir/config/aerospace.toml"
grep -q "alt-0 = 'workspace 10'" \
    "$root_dir/config/aerospace.toml"
grep -q "alt-ctrl-0 = 'exec-and-forget __HOME__/.local/bin/aerospace-show-ambient'" \
    "$root_dir/config/aerospace.toml"
grep -q 'install -m 755 "$root_dir/scripts/aerospace-show-ambient"' \
    "$root_dir/scripts/install.sh"
grep -q "alt-shift-0 = 'move-node-to-workspace --focus-follows-window 10'" \
    "$root_dir/config/aerospace.toml"
grep -Fq 'list-workspaces --monitor focused --empty no | workspace --wrap-around --stdin next' \
    "$root_dir/config/aerospace.toml"
grep -Fq 'Picture in Picture|画中画|Mini ?Player|迷你播放器' \
    "$root_dir/config/aerospace.toml"
grep -q 'aerospace-start-borders' \
    "$root_dir/config/aerospace.toml"
grep -q '^accordion-padding = 0$' \
    "$root_dir/config/aerospace.toml"
grep -q '^gaps.inner.horizontal = 8$' \
    "$root_dir/config/aerospace.toml"
grep -q '^gaps.outer.left = 8$' \
    "$root_dir/config/aerospace.toml"
grep -q 'width=3.0' \
    "$root_dir/scripts/aerospace-start-borders"
grep -q 'active_color=0x4d000000' \
    "$root_dir/scripts/aerospace-start-borders"
if grep -q 'move-workspace-to-monitor' \
    "$root_dir/config/aerospace.toml"; then
    printf 'Force-assigned workspaces cannot be moved between monitors.\n' >&2
    exit 1
fi
if grep -q 'com\.electron\.lark\.helper\|window-title} = 图片和视频' \
    "$root_dir/config/aerospace.toml"; then
    printf 'WeChat and Feishu must not have custom window rules.\n' >&2
    exit 1
fi

personal_matches=$(
    grep -R "/Users/tovizhong\\|com\\.tovizhong" \
        "$root_dir/src" "$root_dir/config" "$root_dir/resources" 2>/dev/null || true
    grep "/Users/tovizhong\\|com\\.tovizhong" \
        "$root_dir/scripts/"* 2>/dev/null |
        grep -v "$root_dir/scripts/test.sh:" |
        grep -F -v 'legacy_pid_file="/tmp/com.tovizhong.aerospace-window-switcher.pid"' ||
        true
)
if [ -n "$personal_matches" ]; then
    printf '%s\n' "$personal_matches"
    printf 'Personal paths or identifiers remain in distributable files.\n' >&2
    exit 1
fi

"$root_dir/scripts/build.sh"
codesign --verify --deep --strict "$root_dir/build/AeroSpaceWindowSwitcher.app"
codesign --verify --strict "$root_dir/build/aerospace-workspace-prompt"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/aerospace-companion-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
test_home="$test_root/home"
mkdir -p "$test_home"
printf '# original config\n' > "$test_home/.aerospace.toml"
mkdir -p \
    "$test_home/.local/share/aerospace-window-switcher/AeroSpaceWindowSwitcher.app"

HOME="$test_home" \
AEROSPACE_COMPANION_SKIP_LAUNCH=1 \
AEROSPACE_COMPANION_SKIP_RELOAD=1 \
"$root_dir/scripts/install.sh" --with-config

test -x "$test_home/.local/bin/aerospace-window-switcher-trigger"
test -x "$test_home/.local/bin/aerospace-move-focused-app-to-workspace"
test -x "$test_home/.local/bin/aerospace-open-terminal-window"
test -x "$test_home/.local/bin/aerospace-start-borders"
test -x "$test_home/.local/bin/aerospace-show-ambient"
test ! -e "$test_home/.local/bin/aerospace-float-secondary-window"
test -x "$test_home/.local/bin/aerospace-companion-update"
test -x "$test_home/.local/bin/aerospace-workspace-prompt"
test -d "$test_home/.local/share/aerospace-companion/AeroSpaceWindowSwitcher.app"
test ! -e "$test_home/.local/share/aerospace-window-switcher"
grep -q '^# AeroSpace Companion configuration' "$test_home/.aerospace.toml"
if grep -q '__HOME__\\|__TERMINAL_APP__' "$test_home/.aerospace.toml"; then
    printf 'Config placeholders were not rendered.\n' >&2
    exit 1
fi

original_backup=$(
    sed -n 's/^config_backup=//p' \
        "$test_home/.local/share/aerospace-companion/install-state"
)

HOME="$test_home" \
AEROSPACE_COMPANION_SKIP_LAUNCH=1 \
AEROSPACE_COMPANION_SKIP_RELOAD=1 \
"$root_dir/scripts/install.sh" --with-config

updated_backup=$(
    sed -n 's/^config_backup=//p' \
        "$test_home/.local/share/aerospace-companion/install-state"
)
test "$updated_backup" = "$original_backup"

HOME="$test_home" \
AEROSPACE_COMPANION_SKIP_RELOAD=1 \
"$test_home/.local/bin/aerospace-companion-uninstall" --restore-config

grep -q '^# original config' "$test_home/.aerospace.toml"
test ! -e "$test_home/.local/share/aerospace-companion"
test ! -e "$test_home/.local/bin/aerospace-show-ambient"

archive_path="$test_root/aerospace-companion.tar.gz"
tar -czf "$archive_path" \
    --exclude .git \
    --exclude build \
    -C "$(dirname "$root_dir")" \
    "$(basename "$root_dir")"

online_home="$test_root/online-home"
mkdir -p "$online_home"
printf '# online original config\n' > "$online_home/.aerospace.toml"

HOME="$online_home" \
AEROSPACE_COMPANION_ARCHIVE_URL="file://$archive_path" \
AEROSPACE_COMPANION_SKIP_LAUNCH=1 \
AEROSPACE_COMPANION_SKIP_RELOAD=1 \
"$root_dir/scripts/install-online.sh"

test -x "$online_home/.local/bin/aerospace-companion-update"
grep -q '^# AeroSpace Companion configuration' "$online_home/.aerospace.toml"

HOME="$online_home" \
AEROSPACE_COMPANION_SKIP_RELOAD=1 \
"$online_home/.local/bin/aerospace-companion-uninstall" --restore-config

grep -q '^# online original config' "$online_home/.aerospace.toml"
test ! -e "$online_home/.local/share/aerospace-companion"

printf 'All checks passed.\n'
