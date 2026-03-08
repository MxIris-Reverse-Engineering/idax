#!/usr/bin/env bash
# build-xcframework.sh — Build a CIDAX.xcframework (arm64 + x86_64) for macOS.
#
# Usage:
#   build-xcframework.sh [output-dir] [build-type]
#
# Arguments:
#   output-dir   Where to place the .xcframework (default: $SWIFT_DIR/Frameworks)
#   build-type   CMake build type (default: RelWithDebInfo)
#
# Environment:
#   IDASDK       IDA SDK root (passed through to build-libs.sh)
#
# The script calls build-libs.sh twice (arm64, x86_64), merges the resulting
# static libraries with libtool + lipo, compiles the IDA SDK data symbol stubs,
# and packages everything into an XCFramework via xcodebuild.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SWIFT_DIR/../.." && pwd)"

# ── Arguments ──────────────────────────────────────────────────────────────
OUTPUT_DIR="${1:-$SWIFT_DIR/Frameworks}"
BUILD_TYPE="${2:-RelWithDebInfo}"

STAGING="$SWIFT_DIR/.xcframework-staging"
ARCHS=(arm64 x86_64)

echo "==> Building CIDAX.xcframework"
echo "    Output dir:  $OUTPUT_DIR"
echo "    Build type:  $BUILD_TYPE"
echo "    Staging dir: $STAGING"
echo ""

# ── Clean staging ──────────────────────────────────────────────────────────
rm -rf "$STAGING"
mkdir -p "$STAGING"

# ── Step 1: Build per-architecture libraries via build-libs.sh ─────────────
for arch in "${ARCHS[@]}"; do
    echo "==> Building libraries for $arch..."
    "$SCRIPT_DIR/build-libs.sh" \
        --arch "$arch" \
        --output-dir "$STAGING/$arch" \
        --build-type "$BUILD_TYPE"
    echo ""
done

# ── Step 2: Merge libidax.a + libidax_shim.a → libCIDAX.a per arch ────────
for arch in "${ARCHS[@]}"; do
    echo "==> Merging static libraries for $arch..."
    ARCH_DIR="$STAGING/$arch"
    libtool -static \
        "$ARCH_DIR/libidax.a" \
        "$ARCH_DIR/libidax_shim.a" \
        -o "$ARCH_DIR/libCIDAX.a"
    echo "    Created $ARCH_DIR/libCIDAX.a"
done

# ── Step 3: Compile stubs (callui, dbg, under_debugger) per arch ───────────
STUBS_SRC="$SWIFT_DIR/Sources/CIDAX/shim.c"
for arch in "${ARCHS[@]}"; do
    echo "==> Compiling SDK data stubs for $arch..."
    ARCH_DIR="$STAGING/$arch"
    STUBS_OBJ="$ARCH_DIR/shim_stubs.o"

    cc -arch "$arch" -c "$STUBS_SRC" -o "$STUBS_OBJ" -O2
    ar r "$ARCH_DIR/libCIDAX.a" "$STUBS_OBJ"
    rm -f "$STUBS_OBJ"
    echo "    Added stubs to $ARCH_DIR/libCIDAX.a"
done

# ── Step 4: Create universal (fat) library with lipo ───────────────────────
echo "==> Creating universal fat library..."
mkdir -p "$STAGING/universal"
lipo -create \
    "$STAGING/arm64/libCIDAX.a" \
    "$STAGING/x86_64/libCIDAX.a" \
    -output "$STAGING/universal/libCIDAX.a"
echo "    $(lipo -info "$STAGING/universal/libCIDAX.a")"

# ── Step 5: Prepare headers + modulemap ────────────────────────────────────
echo "==> Preparing headers..."
HEADERS_DIR="$STAGING/headers"
mkdir -p "$HEADERS_DIR"
cp "$SWIFT_DIR/Sources/CIDAX/include/idax_shim.h" "$HEADERS_DIR/"

cat > "$HEADERS_DIR/module.modulemap" <<'MODULEMAP'
module CIDAX {
    header "idax_shim.h"
    export *
}
MODULEMAP
echo "    Headers ready at $HEADERS_DIR"

# ── Step 6: Create XCFramework ─────────────────────────────────────────────
echo "==> Creating XCFramework..."
mkdir -p "$OUTPUT_DIR"

# Remove any previous XCFramework
rm -rf "$OUTPUT_DIR/CIDAX.xcframework"

xcodebuild -create-xcframework \
    -library "$STAGING/universal/libCIDAX.a" \
    -headers "$HEADERS_DIR" \
    -output "$OUTPUT_DIR/CIDAX.xcframework"

# ── Step 7: Clean up staging ──────────────────────────────────────────────
rm -rf "$STAGING"

# ── Step 8: Verify and print summary ──────────────────────────────────────
echo ""
echo "==> CIDAX.xcframework created successfully!"
echo ""
echo "--- Structure ---"
ls -R "$OUTPUT_DIR/CIDAX.xcframework"
echo ""

# Find the library inside the xcframework
XCFW_LIB="$(find "$OUTPUT_DIR/CIDAX.xcframework" -name 'libCIDAX.a' -print -quit)"
if [ -n "$XCFW_LIB" ]; then
    echo "--- Architecture info ---"
    lipo -info "$XCFW_LIB"
    echo ""
    echo "--- Stub symbol check ---"
    nm "$XCFW_LIB" | grep '_callui' || echo "WARNING: _callui stub not found!"
    echo ""
fi

echo "==> Done: $OUTPUT_DIR/CIDAX.xcframework"
