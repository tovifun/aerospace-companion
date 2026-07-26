#!/bin/sh

set -eu

repository=${AEROSPACE_COMPANION_REPOSITORY:-tovifun/aerospace-companion}
revision=${AEROSPACE_COMPANION_REVISION:-main}
archive_url=${AEROSPACE_COMPANION_ARCHIVE_URL:-"https://github.com/$repository/archive/$revision.tar.gz"}
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/aerospace-companion-download.XXXXXX")

cleanup() {
    rm -rf "$temp_dir"
}
trap cleanup EXIT HUP INT TERM

if ! command -v curl >/dev/null 2>&1; then
    printf 'curl is required to download AeroSpace Companion.\n' >&2
    exit 1
fi

printf 'Downloading AeroSpace Companion (%s)...\n' "$revision"
curl -fsSL "$archive_url" | tar -xz -C "$temp_dir"

source_dir=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [ -z "$source_dir" ] || [ ! -x "$source_dir/scripts/install.sh" ]; then
    printf 'The downloaded archive does not contain a valid installer.\n' >&2
    exit 1
fi

if [ "$#" -eq 0 ]; then
    set -- --with-config
fi

"$source_dir/scripts/install.sh" "$@"
