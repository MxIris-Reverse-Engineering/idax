#!/usr/bin/env bash
# build-libs.sh — Build libidax_swift_native.a for the Swift package.
#
# The Swift package links this one archive: upstream's bindings/swift/
# CMakeLists.txt builds it from the IDAX sources, the canonical C transport
# shared with Rust, and the private Swift bridge adapters.
#
# Upstream expects consumers to run CMake and then point PKG_CONFIG_PATH at the
# generated metadata. This fork keeps a prebuilt-artifact route instead, so
# `swift build` works with no environment beyond IDADIR: Package.swift looks for
# the archive in the output directory below and links it directly.
#
# Usage:
#   build-libs.sh [options]
#
# Options:
#   --output-dir <dir>     Where to place the built archive.
#                          Default: bindings/swift/.build-libs
#   --build-dir <dir>      CMake build tree. Default: bindings/swift/.cmake-build
#   --build-type <type>    CMake build type. Default: Release
#   -h, --help             Show this help message.
#
# Environment:
#   IDADIR   Required. IDA 9.4 directory containing libida and libidalib.
#   IDASDK   Optional. IDA SDK source root. CMake fetches one when unset.
set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
swift_directory="$(cd "$script_directory/.." && pwd)"
repository_root="$(cd "$swift_directory/../.." && pwd)"

output_directory=""
build_directory=""
build_type=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) output_directory="$2"; shift 2 ;;
        --build-dir)  build_directory="$2";  shift 2 ;;
        --build-type) build_type="$2";       shift 2 ;;
        -h|--help)
            sed -n '2,/^set /{ /^#/!d; s/^# \{0,1\}//; p; }' "$0"
            exit 0 ;;
        *)
            printf 'ERROR: Unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
done

output_directory="${output_directory:-$swift_directory/.build-libs}"
build_directory="${build_directory:-$swift_directory/.cmake-build}"
build_type="${build_type:-Release}"

if [[ -z "${IDADIR:-}" ]]; then
    printf 'ERROR: Set IDADIR to the IDA 9.4 directory containing libida and libidalib.\n' >&2
    exit 1
fi
for library in ida idalib; do
    if [[ ! -f "$IDADIR/lib${library}.dylib" ]]; then
        printf 'ERROR: %s holds no lib%s.dylib.\n' "$IDADIR" "$library" >&2
        exit 1
    fi
done

cmake_arguments=(
    -S "$repository_root"
    -B "$build_directory"
    -DCMAKE_BUILD_TYPE="$build_type"
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
    -DIDAX_BUILD_SWIFT=ON
    -DIDAX_SWIFT_RUNTIME_DIR="$IDADIR"
    -DIDAX_BUILD_TESTS=OFF
    -DIDAX_BUILD_EXAMPLES=OFF
)
if [[ -n "${IDASDK:-}" ]]; then
    cmake_arguments+=(-DIDASDK="$IDASDK")
fi

printf '==> Configuring (%s)\n' "$build_type"
cmake "${cmake_arguments[@]}"

printf '==> Building idax_swift_native\n'
cmake --build "$build_directory" --target idax_swift_native --config "$build_type" --parallel

archive_path="$(find "$build_directory" -name 'libidax_swift_native.a' -print -quit)"
if [[ -z "$archive_path" ]]; then
    printf 'ERROR: libidax_swift_native.a not found under %s\n' "$build_directory" >&2
    exit 1
fi

mkdir -p "$output_directory"
cp "$archive_path" "$output_directory/libidax_swift_native.a"

printf '==> Archive ready:\n'
ls -la "$output_directory/libidax_swift_native.a"
printf '\nBuild the tool with:\n    swift build --product idax\n'
