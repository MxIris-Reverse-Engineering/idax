#!/usr/bin/env bash
# Build and install the dyld cache database creator for the current user.
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
product_name="idax"
installation_prefix="${IDAX_INSTALLATION_PREFIX:-$HOME/.local}"
binary_installation_directory="$installation_prefix/bin"
product_installation_directory="$installation_prefix/libexec/$product_name"
launcher_path="$binary_installation_directory/$product_name"
shell_configuration_path="$HOME/.zshrc"

require_command() {
    local required_command_name="$1"

    if ! command -v "$required_command_name" >/dev/null 2>&1; then
        printf 'ERROR: Required command not found: %s\n' "$required_command_name" >&2
        exit 1
    fi
}

require_command swift
require_command cmake
require_command install

if [[ -z "${IDADIR:-}" ]]; then
    printf 'ERROR: Set IDADIR to the IDA 9.4 directory containing libida and libidalib.\n' >&2
    exit 1
fi

# The Swift package links one prebuilt native archive. Building it here keeps
# `swift build` free of any pkg-config setup; see bindings/swift/scripts/.
printf '==> Building the native archive\n'
"$repository_root/bindings/swift/scripts/build-libs.sh"

printf '==> Updating Swift package dependencies\n'
swift package --package-path "$repository_root" update

printf '==> Building %s in release configuration\n' "$product_name"
swift build \
    --package-path "$repository_root" \
    --configuration release \
    --product "$product_name"

release_products_directory="$(
    swift build \
        --package-path "$repository_root" \
        --configuration release \
        --show-bin-path
)"
source_executable_path="$release_products_directory/$product_name"

if [[ ! -x "$source_executable_path" ]]; then
    printf 'ERROR: Built executable not found: %s\n' "$source_executable_path" >&2
    exit 1
fi

# The executable statically links the native archive and carries an rpath to
# the IDA runtime, so the binary is the only artifact to install.
printf '==> Installing runtime files into %s\n' "$product_installation_directory"
mkdir -p "$product_installation_directory" "$binary_installation_directory"
install -m 755 "$source_executable_path" "$product_installation_directory/$product_name"

escaped_installed_executable_path="$(printf '%q' "$product_installation_directory/$product_name")"
temporary_launcher_path="$(mktemp "${TMPDIR:-/tmp}/${product_name}.launcher.XXXXXX")"

cleanup_temporary_launcher() {
    if [[ -f "$temporary_launcher_path" ]]; then
        rm -f "$temporary_launcher_path"
    fi
}

trap cleanup_temporary_launcher EXIT

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    "installed_executable_path=$escaped_installed_executable_path" \
    'exec "$installed_executable_path" "$@"' \
    > "$temporary_launcher_path"
install -m 755 "$temporary_launcher_path" "$launcher_path"

printf '==> Verifying installed command\n'
"$launcher_path" --help >/dev/null

case ":$PATH:" in
    *":$binary_installation_directory:"*)
        printf 'Installed successfully: %s\n' "$launcher_path"
        printf 'Run: %s --help\n' "$product_name"
        ;;
    *)
        path_configuration_line="export PATH=\"$binary_installation_directory:\$PATH\""
        if [[ ! -f "$shell_configuration_path" ]] || \
            ! grep -Fqx "$path_configuration_line" "$shell_configuration_path"; then
            printf '\n%s\n' "$path_configuration_line" >> "$shell_configuration_path"
        fi

        printf 'Installed successfully: %s\n' "$launcher_path"
        printf 'Added %s to %s. Open a new terminal, then run: %s --help\n' \
            "$binary_installation_directory" \
            "$shell_configuration_path" \
            "$product_name"
        ;;
esac
