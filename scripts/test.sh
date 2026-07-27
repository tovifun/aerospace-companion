#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(dirname "$script_dir")

sh -n "$root_dir/scripts/build.sh"
sh -n "$root_dir/scripts/install.sh"
sh -n "$root_dir/scripts/install-online.sh"
sh -n "$root_dir/scripts/uninstall.sh"
sh -n "$root_dir/scripts/aerospace-window-switcher-trigger"
zsh -n "$root_dir/scripts/aerospace-float-secondary-window"
zsh -n "$root_dir/scripts/aerospace-move-focused-app-to-workspace"
plutil -lint "$root_dir/resources/Info.plist"

grep -q 'loadWindows(presentErrors: false)' \
    "$root_dir/src/window-switcher/main.swift"
grep -q 'AeroSpaceClient.activate(workspace: window.workspace)' \
    "$root_dir/src/window-switcher/main.swift"

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
test -x "$test_home/.local/bin/aerospace-float-secondary-window"
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
