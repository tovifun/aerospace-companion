#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(dirname "$script_dir")
install_root=${AEROSPACE_COMPANION_HOME:-"$HOME/.local/share/aerospace-companion"}
bin_dir=${AEROSPACE_COMPANION_BIN_DIR:-"$HOME/.local/bin"}
with_config=0

usage() {
    cat <<'EOF'
Usage: ./scripts/install.sh [--with-config]

  --with-config  Back up and replace the active AeroSpace config.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --with-config) with_config=1 ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ "$(uname -s)" != "Darwin" ]; then
    printf 'AeroSpace Companion requires macOS.\n' >&2
    exit 1
fi

"$root_dir/scripts/build.sh"

runtime_id=io.github.tovifun.aerospace-companion.window-switcher
pid_file="/tmp/$runtime_id.$(/usr/bin/id -u).pid"
app_dest="$install_root/AeroSpaceWindowSwitcher.app"
state_file="$install_root/install-state"
first_install=1
previous_config_path=
previous_config_backup=
previous_config_created=0

if [ -f "$state_file" ]; then
    first_install=0
    previous_config_path=$(sed -n 's/^config_path=//p' "$state_file")
    previous_config_backup=$(sed -n 's/^config_backup=//p' "$state_file")
    previous_config_created=$(sed -n 's/^config_created=//p' "$state_file")
fi

if [ -r "$pid_file" ]; then
    pid=$(/bin/cat "$pid_file" 2>/dev/null || true)
    case "$pid" in
        ''|*[!0-9]*) ;;
        *)
            command=$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)
            case "$command" in
                *"$app_dest/Contents/MacOS/aerospace-window-switcher"*)
                    /bin/kill "$pid" 2>/dev/null || true
                    ;;
            esac
            ;;
    esac
fi

mkdir -p "$install_root" "$bin_dir"
rm -f "$bin_dir/aerospace-float-secondary-window"
case "$app_dest" in
    "$HOME/.local/share/aerospace-companion/AeroSpaceWindowSwitcher.app")
        rm -rf "$app_dest"
        ;;
    *)
        if [ -e "$app_dest" ]; then
            printf 'Refusing to replace unexpected path: %s\n' "$app_dest" >&2
            exit 1
        fi
        ;;
esac

/usr/bin/ditto "$root_dir/build/AeroSpaceWindowSwitcher.app" "$app_dest"
install -m 755 "$root_dir/build/aerospace-workspace-prompt" \
    "$bin_dir/aerospace-workspace-prompt"
install -m 755 "$root_dir/scripts/aerospace-window-switcher-trigger" \
    "$bin_dir/aerospace-window-switcher-trigger"
install -m 755 "$root_dir/scripts/aerospace-move-focused-app-to-workspace" \
    "$bin_dir/aerospace-move-focused-app-to-workspace"
install -m 755 "$root_dir/scripts/install-online.sh" \
    "$bin_dir/aerospace-companion-update"
install -m 755 "$root_dir/scripts/uninstall.sh" \
    "$bin_dir/aerospace-companion-uninstall"

config_path=
config_backup=
config_created=0

if [ "$with_config" -eq 1 ]; then
    if [ -n "${AEROSPACE_CONFIG_PATH:-}" ]; then
        config_path=$AEROSPACE_CONFIG_PATH
    elif [ -f "$HOME/.aerospace.toml" ]; then
        config_path="$HOME/.aerospace.toml"
    elif [ -f "$HOME/.config/aerospace/aerospace.toml" ]; then
        config_path="$HOME/.config/aerospace/aerospace.toml"
    else
        config_path="$HOME/.aerospace.toml"
        config_created=1
    fi

    mkdir -p "$(dirname "$config_path")"
    if [ -f "$config_path" ]; then
        timestamp=$(date '+%Y%m%d-%H%M%S')
        config_backup="$config_path.aerospace-companion-backup-$timestamp"
        cp -p "$config_path" "$config_backup"
    fi

    terminal_app=${AEROSPACE_TERMINAL_APP:-Ghostty}
    escaped_home=$(printf '%s' "$HOME" | sed 's/[&|\\]/\\&/g')
    escaped_terminal=$(printf '%s' "$terminal_app" | sed 's/[&|\\]/\\&/g')
    rendered_config=$(mktemp "${TMPDIR:-/tmp}/aerospace-companion-config.XXXXXX")
    sed \
        -e "s|__HOME__|$escaped_home|g" \
        -e "s|__TERMINAL_APP__|$escaped_terminal|g" \
        "$root_dir/config/aerospace.toml" > "$rendered_config"
    install -m 644 "$rendered_config" "$config_path"
    rm -f "$rendered_config"
fi

find_aerospace() {
    if command -v aerospace >/dev/null 2>&1; then
        command -v aerospace
    elif [ -x /opt/homebrew/bin/aerospace ]; then
        printf '/opt/homebrew/bin/aerospace\n'
    elif [ -x /usr/local/bin/aerospace ]; then
        printf '/usr/local/bin/aerospace\n'
    fi
    return 0
}

aerospace_bin=$(find_aerospace)
if [ "$with_config" -eq 1 ] &&
   [ "${AEROSPACE_COMPANION_SKIP_RELOAD:-0}" != "1" ] &&
   [ -n "$aerospace_bin" ] &&
   "$aerospace_bin" list-workspaces --all >/dev/null 2>&1; then
    if ! "$aerospace_bin" reload-config --dry-run --warnings-as-errors; then
        if [ -n "$config_backup" ]; then
            cp -p "$config_backup" "$config_path"
        elif [ "$config_created" -eq 1 ]; then
            rm -f "$config_path"
        fi
        printf 'Config validation failed; the previous config was restored.\n' >&2
        exit 1
    fi
    "$aerospace_bin" reload-config
fi

state_config_path=$config_path
state_config_backup=$config_backup
state_config_created=$config_created

if [ -n "$previous_config_path" ] &&
   { [ "$with_config" -eq 0 ] || [ "$previous_config_path" = "$config_path" ]; }; then
    state_config_path=$previous_config_path
    state_config_backup=$previous_config_backup
    state_config_created=$previous_config_created
fi

{
    printf 'config_path=%s\n' "$state_config_path"
    printf 'config_backup=%s\n' "$state_config_backup"
    printf 'config_created=%s\n' "$state_config_created"
} > "$state_file"

migrate_legacy_install() {
    legacy_root="$HOME/.local/share/aerospace-window-switcher"
    legacy_app="$legacy_root/AeroSpaceWindowSwitcher.app"
    legacy_binary="$legacy_app/Contents/MacOS/aerospace-window-switcher"
    legacy_pid_file="/tmp/com.tovizhong.aerospace-window-switcher.pid"
    legacy_pids=

    if [ -r "$legacy_pid_file" ]; then
        legacy_pid=$(/bin/cat "$legacy_pid_file" 2>/dev/null || true)
        legacy_pids=$legacy_pid
    fi

    if [ -x /usr/bin/pgrep ]; then
        detected_legacy_pids=$(
            /usr/bin/pgrep -f "$legacy_binary" 2>/dev/null || true
        )
        legacy_pids="$legacy_pids $detected_legacy_pids"
    fi

    for legacy_pid in $legacy_pids; do
        case "$legacy_pid" in
            ''|*[!0-9]*) continue ;;
        esac

        legacy_command=$(
            /bin/ps -p "$legacy_pid" -o command= 2>/dev/null || true
        )
        case "$legacy_command" in
            *"$legacy_binary"*)
                /bin/kill "$legacy_pid" 2>/dev/null || true
                ;;
        esac
    done

    case "$legacy_root" in
        "$HOME/.local/share/aerospace-window-switcher")
            rm -rf "$legacy_root"
            rm -f "$legacy_pid_file"
            ;;
    esac
}

migrate_legacy_install

if [ "${AEROSPACE_COMPANION_SKIP_LAUNCH:-0}" != "1" ]; then
    /usr/bin/open -gj "$app_dest" --args --daemon
fi

printf '\nAeroSpace Companion installed.\n'
printf 'Tools:  %s\n' "$install_root"
if [ "$first_install" -eq 1 ] && \
   [ "${AEROSPACE_COMPANION_SKIP_LAUNCH:-0}" != "1" ]; then
    printf 'First run: follow the permission guide for Accessibility and Input Monitoring.\n'
fi
if [ "$with_config" -eq 1 ]; then
    printf 'Config: %s\n' "$config_path"
    if [ -n "$config_backup" ]; then
        printf 'Backup: %s\n' "$config_backup"
    fi
else
    printf 'Config was not changed. Re-run with --with-config to install it.\n'
fi
