#!/bin/sh

set -eu

install_root=${AEROSPACE_COMPANION_HOME:-"$HOME/.local/share/aerospace-companion"}
bin_dir=${AEROSPACE_COMPANION_BIN_DIR:-"$HOME/.local/bin"}
restore_config=0

case "${1:-}" in
    "") ;;
    --restore-config) restore_config=1 ;;
    -h|--help)
        printf 'Usage: aerospace-companion-uninstall [--restore-config]\n'
        exit 0
        ;;
    *)
        printf 'Usage: aerospace-companion-uninstall [--restore-config]\n' >&2
        exit 2
        ;;
esac

state_file="$install_root/install-state"
config_path=
config_backup=
config_created=0

if [ -f "$state_file" ]; then
    config_path=$(sed -n 's/^config_path=//p' "$state_file")
    config_backup=$(sed -n 's/^config_backup=//p' "$state_file")
    config_created=$(sed -n 's/^config_created=//p' "$state_file")
fi

runtime_id=io.github.tovifun.aerospace-companion.window-switcher
pid_file="/tmp/$runtime_id.$(/usr/bin/id -u).pid"
app="$install_root/AeroSpaceWindowSwitcher.app"

if [ -r "$pid_file" ]; then
    pid=$(/bin/cat "$pid_file" 2>/dev/null || true)
    case "$pid" in
        ''|*[!0-9]*) ;;
        *)
            command=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
            case "$command" in
                *"$app/Contents/MacOS/aerospace-window-switcher"*)
                    /bin/kill "$pid" 2>/dev/null || true
                    ;;
            esac
            ;;
    esac
fi

if [ "$restore_config" -eq 1 ] && [ -n "$config_path" ]; then
    if [ -n "$config_backup" ] && [ -f "$config_backup" ]; then
        cp -p "$config_backup" "$config_path"
        printf 'Restored %s\n' "$config_path"
    elif [ "$config_created" = "1" ] &&
         [ -f "$config_path" ] &&
         grep -q '^# AeroSpace Companion configuration' "$config_path"; then
        rm -f "$config_path"
        printf 'Removed %s\n' "$config_path"
    fi
fi

case "$install_root" in
    "$HOME/.local/share/aerospace-companion")
        rm -rf "$install_root"
        ;;
    *)
        printf 'Refusing to remove unexpected path: %s\n' "$install_root" >&2
        exit 1
        ;;
esac

rm -f \
    "$bin_dir/aerospace-workspace-prompt" \
    "$bin_dir/aerospace-window-switcher-trigger" \
    "$bin_dir/aerospace-move-focused-app-to-workspace" \
    "$bin_dir/aerospace-float-secondary-window" \
    "$bin_dir/aerospace-companion-update" \
    "$bin_dir/aerospace-companion-uninstall"

printf 'AeroSpace Companion uninstalled.\n'
