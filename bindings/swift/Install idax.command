#!/usr/bin/env bash
# Install idax.command — double-click this file in Finder to install the tool.
#
# Terminal.app registers the .command extension, so double-clicking opens a
# window and runs this file. That is the whole reason it exists rather than a
# SwiftPM command plugin: SwiftPM runs command plugins under sandbox-exec, and
# the only writable locations are the plugin's output directory, the package
# directory, and whatever `--allow-writing-to-directory` names. Installing into
# ~/.local is therefore denied, and Xcode's plugin dialog can pass neither that
# option nor --disable-sandbox.
#
# This file holds no installation logic. install_idax_command_line.sh remains
# the single source of truth; this only supplies what a double-clicked process
# does not reliably inherit — a PATH containing cmake, an IDADIR, and a working
# directory that is not the user's home.
#
# A copy extracted from a downloaded archive carries com.apple.quarantine and
# Gatekeeper will refuse to run it. Clear it with:
#     xattr -d com.apple.quarantine "Install idax.command"
# A checkout made with git carries no such attribute.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/../.." && pwd)"
installation_script_path="$script_directory/scripts/install_idax_command_line.sh"

# Runs on every exit path, so a failure message survives long enough to be read
# even when Terminal is configured to close its window when the shell exits.
pause_before_closing_window() {
    local exit_status=$?

    printf '\n'
    if [[ $exit_status -eq 0 ]]; then
        printf 'Done. Press any key to close this window.\n'
    else
        printf 'Failed with exit status %d. Press any key to close this window.\n' \
            "$exit_status"
    fi

    # Guarded so that running this file from a script does not hang forever.
    if [[ -t 0 ]]; then
        read -r -n 1 -s
    fi
}

trap pause_before_closing_window EXIT

# Appended rather than prepended: a PATH the user configured deliberately should
# keep deciding which toolchain wins. These only fill the gap left when the
# double-clicked shell starts without a login profile.
append_conventional_tool_directories_to_path() {
    local conventional_tool_directories=(
        # Homebrew on Apple silicon, Homebrew on Intel, CMake.app's own
        # command-line tools, MacPorts.
        /opt/homebrew/bin
        /usr/local/bin
        /Applications/CMake.app/Contents/bin
        /opt/local/bin
    )
    local tool_directory

    for tool_directory in "${conventional_tool_directories[@]}"; do
        if [[ -d "$tool_directory" ]] && [[ ":$PATH:" != *":$tool_directory:"* ]]; then
            PATH="$PATH:$tool_directory"
        fi
    done

    export PATH
}

# Mirrors the discovery order in Package.swift and in the BuildNativeLibrary
# plugin: an explicit IDADIR first, then the newest /Applications/IDA*.app whose
# runtime directory actually holds libida.
locate_ida_runtime_directory() {
    local application_bundle_path

    if [[ -n "${IDADIR:-}" ]] && [[ -f "$IDADIR/libida.dylib" ]]; then
        printf '%s' "$IDADIR"
        return 0
    fi

    while IFS= read -r application_bundle_path; do
        if [[ -f "$application_bundle_path/Contents/MacOS/libida.dylib" ]]; then
            printf '%s' "$application_bundle_path/Contents/MacOS"
            return 0
        fi
    done < <(find /Applications -maxdepth 1 -name 'IDA*.app' | sort -r)

    return 1
}

if [[ ! -f "$installation_script_path" ]]; then
    printf 'ERROR: Installation script not found: %s\n' "$installation_script_path" >&2
    printf 'Run this file from inside a complete checkout of the repository.\n' >&2
    exit 1
fi

append_conventional_tool_directories_to_path

if ! ida_runtime_directory="$(locate_ida_runtime_directory)"; then
    printf 'ERROR: No IDA runtime found.\n' >&2
    printf 'A double-clicked process does not inherit IDADIR from a shell, and no\n' >&2
    printf '/Applications/IDA*.app holds libida.dylib. Install IDA 9.4, or run the\n' >&2
    printf 'installer from a terminal with IDADIR set:\n' >&2
    printf '    %s\n' "$installation_script_path" >&2
    exit 1
fi

export IDADIR="$ida_runtime_directory"

printf '==> Repository:  %s\n' "$repository_root"
printf '==> IDA runtime: %s\n' "$IDADIR"
printf '\n'

cd "$repository_root"
"$installation_script_path"
