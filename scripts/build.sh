#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root_dir=$(dirname "$script_dir")
build_dir=${BUILD_DIR:-"$root_dir/build"}
app="$build_dir/AeroSpaceWindowSwitcher.app"

case "$build_dir" in
    "$root_dir"/build|/tmp/*) ;;
    *)
        printf 'Refusing to clean unexpected build directory: %s\n' "$build_dir" >&2
        exit 1
        ;;
esac

if ! command -v xcrun >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
    printf 'Apple Command Line Tools are required. Run: xcode-select --install\n' >&2
    exit 1
fi

arch=$(uname -m)
case "$arch" in
    arm64|x86_64) ;;
    *)
        printf 'Unsupported architecture: %s\n' "$arch" >&2
        exit 1
        ;;
esac

rm -rf "$build_dir"
mkdir -p "$app/Contents/MacOS"
cp "$root_dir/resources/Info.plist" "$app/Contents/Info.plist"

xcrun swiftc \
    -O \
    -target "$arch-apple-macos13.0" \
    -framework ApplicationServices \
    -framework Cocoa \
    -framework Carbon \
    -framework QuartzCore \
    "$root_dir/src/window-switcher/main.swift" \
    -o "$app/Contents/MacOS/aerospace-window-switcher"

xcrun swiftc \
    -O \
    -target "$arch-apple-macos13.0" \
    -framework AppKit \
    "$root_dir/src/workspace-prompt/main.swift" \
    -o "$build_dir/aerospace-workspace-prompt"

codesign --force --deep --sign - \
    --requirements '=designated => identifier "io.github.tovifun.aerospace-companion.window-switcher"' \
    "$app"
codesign --force --sign - "$build_dir/aerospace-workspace-prompt"

printf 'Built %s\n' "$app"
