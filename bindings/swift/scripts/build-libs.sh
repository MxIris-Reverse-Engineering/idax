#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SWIFT_DIR/../.." && pwd)"
OUTPUT_DIR="${1:-$SWIFT_DIR/.build-libs}"
BUILD_TYPE="${2:-RelWithDebInfo}"

echo "==> Building idax static library..."
BUILD_DIR="$SWIFT_DIR/.cmake-build"
cmake -S "$REPO_ROOT" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DIDAX_BUILD_TESTS=OFF \
    -DIDAX_BUILD_EXAMPLES=OFF

cmake --build "$BUILD_DIR" --target idax --config "$BUILD_TYPE"

echo "==> Building C shim..."
mkdir -p "$OUTPUT_DIR"

# Find the built libidax.a
LIBIDAX="$(find "$BUILD_DIR" -name 'libidax.a' -print -quit)"
if [ -z "$LIBIDAX" ]; then
    echo "ERROR: libidax.a not found in $BUILD_DIR" >&2
    exit 1
fi
cp "$LIBIDAX" "$OUTPUT_DIR/libidax.a"

# Compile the C shim into a static library
SHIM_CPP="$REPO_ROOT/bindings/rust/idax-sys/shim/idax_shim.cpp"
IDASDK="${IDASDK:-}"

if [ -z "$IDASDK" ]; then
    echo "ERROR: IDASDK environment variable not set" >&2
    exit 1
fi

# Resolve SDK include path (handle both layouts)
SDK_INCLUDE="$IDASDK/include"
if [ ! -d "$SDK_INCLUDE" ] && [ -d "$IDASDK/src/include" ]; then
    SDK_INCLUDE="$IDASDK/src/include"
fi

SHIM_OBJ="$OUTPUT_DIR/idax_shim.o"

# Detect C++ standard flag
CXX="${CXX:-c++}"
if $CXX -std=c++23 -x c++ /dev/null -fsyntax-only 2>/dev/null; then
    STD_FLAG="-std=c++23"
else
    STD_FLAG="-std=c++2b"
fi

$CXX $STD_FLAG -c "$SHIM_CPP" -o "$SHIM_OBJ" \
    -I"$REPO_ROOT/include" \
    -I"$REPO_ROOT/src" \
    -I"$SDK_INCLUDE" \
    -D__EA64__ \
    -fPIC -O2

ar rcs "$OUTPUT_DIR/libidax_shim.a" "$SHIM_OBJ"
rm -f "$SHIM_OBJ"

echo "==> Libraries ready in $OUTPUT_DIR:"
ls -la "$OUTPUT_DIR"/*.a
