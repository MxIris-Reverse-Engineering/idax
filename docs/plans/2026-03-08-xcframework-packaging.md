# XCFramework Packaging Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Package libidax + shim into a CIDAX.xcframework (macOS arm64 + x86_64) with dual-mode Package.swift.

**Architecture:** Two shell scripts — `build-libs.sh` (modified to accept `--arch`) and `build-xcframework.sh` (new orchestrator). Package.swift switches between dev mode (unsafeFlags) and consumer mode (binaryTarget) via `IDAX_DEV` env var.

**Tech Stack:** Bash, CMake, libtool, lipo, xcodebuild -create-xcframework, SPM

---

### Task 1: Modify build-libs.sh to support --arch and --output-dir

**Files:**
- Modify: `bindings/swift/scripts/build-libs.sh`

**Step 1: Add argument parsing**

Replace the positional `$1`/`$2` args with flag-based parsing. Add `--arch`, `--output-dir`, and `--build-type` flags. When `--arch` is set, pass `-DCMAKE_OSX_ARCHITECTURES` to CMake and `-arch` to the C++ compiler.

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SWIFT_DIR/../.." && pwd)"

# Defaults
ARCH=""
OUTPUT_DIR="$SWIFT_DIR/.build-libs"
BUILD_TYPE="RelWithDebInfo"

while [[ $# -gt 0 ]]; do
    case $1 in
        --arch)       ARCH="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --build-type) BUILD_TYPE="$2"; shift 2 ;;
        *)            OUTPUT_DIR="$1"; BUILD_TYPE="${2:-$BUILD_TYPE}"; break ;;
    esac
done

# Architecture-specific build directory to avoid collisions
if [ -n "$ARCH" ]; then
    BUILD_DIR="$SWIFT_DIR/.cmake-build-$ARCH"
else
    BUILD_DIR="$SWIFT_DIR/.cmake-build"
fi

echo "==> Building idax static library${ARCH:+ ($ARCH)}..."
CMAKE_ARGS=(
    -S "$REPO_ROOT" -B "$BUILD_DIR"
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    -DIDAX_BUILD_TESTS=OFF
    -DIDAX_BUILD_EXAMPLES=OFF
)
if [ -n "$ARCH" ]; then
    CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES="$ARCH")
fi
cmake "${CMAKE_ARGS[@]}"
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

# Compile the C shim
SHIM_CPP="$REPO_ROOT/bindings/rust/idax-sys/shim/idax_shim.cpp"
IDASDK="${IDASDK:-}"

if [ -z "$IDASDK" ]; then
    FETCHED_SDK="$BUILD_DIR/_deps/ida_sdk-src"
    if [ -d "$FETCHED_SDK" ]; then
        echo "    Using FetchContent SDK at $FETCHED_SDK"
        IDASDK="$FETCHED_SDK"
    else
        echo "ERROR: IDASDK not set and no FetchContent SDK found" >&2
        exit 1
    fi
fi

SDK_INCLUDE="$IDASDK/include"
if [ ! -d "$SDK_INCLUDE" ] && [ -d "$IDASDK/src/include" ]; then
    SDK_INCLUDE="$IDASDK/src/include"
fi

CXX="${CXX:-c++}"
if $CXX -std=c++23 -x c++ /dev/null -fsyntax-only 2>/dev/null; then
    STD_FLAG="-std=c++23"
else
    STD_FLAG="-std=c++2b"
fi

ARCH_FLAGS=""
if [ -n "$ARCH" ]; then
    ARCH_FLAGS="-arch $ARCH"
fi

SHIM_OBJ="$OUTPUT_DIR/idax_shim.o"
$CXX $STD_FLAG $ARCH_FLAGS -c "$SHIM_CPP" -o "$SHIM_OBJ" \
    -I"$REPO_ROOT/include" \
    -I"$REPO_ROOT/src" \
    -I"$SDK_INCLUDE" \
    -D__EA64__ \
    -fPIC -O2

ar rcs "$OUTPUT_DIR/libidax_shim.a" "$SHIM_OBJ"
rm -f "$SHIM_OBJ"

echo "==> Libraries ready in $OUTPUT_DIR:"
ls -la "$OUTPUT_DIR"/*.a
```

**Step 2: Verify it still works without --arch (backwards compat)**

Run: `bindings/swift/scripts/build-libs.sh`
Expected: builds as before into `bindings/swift/.build-libs/`

**Step 3: Verify --arch arm64 works**

Run: `bindings/swift/scripts/build-libs.sh --arch arm64 --output-dir /tmp/idax-arm64`
Expected: `lipo -info /tmp/idax-arm64/libidax.a` shows `arm64`

**Step 4: Commit**

```bash
git add bindings/swift/scripts/build-libs.sh
git commit -s -m "refactor(swift): add --arch and --output-dir flags to build-libs.sh"
```

---

### Task 2: Create build-xcframework.sh

**Files:**
- Create: `bindings/swift/scripts/build-xcframework.sh`

**Step 1: Write the script**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SWIFT_DIR/../.." && pwd)"
OUTPUT_DIR="${1:-$SWIFT_DIR/Frameworks}"
BUILD_TYPE="${2:-RelWithDebInfo}"
STAGING="$SWIFT_DIR/.xcframework-staging"

echo "==> Building CIDAX.xcframework (arm64 + x86_64)..."

# Clean staging area
rm -rf "$STAGING"
mkdir -p "$STAGING"/{arm64,x86_64,universal,headers}

# Step 1 & 2: Build for each architecture
for arch in arm64 x86_64; do
    echo "--- Building for $arch ---"
    "$SCRIPT_DIR/build-libs.sh" \
        --arch "$arch" \
        --output-dir "$STAGING/$arch" \
        --build-type "$BUILD_TYPE"
done

# Step 3: Merge libidax.a + libidax_shim.a per architecture
for arch in arm64 x86_64; do
    echo "--- Merging static libraries ($arch) ---"
    libtool -static -o "$STAGING/$arch/libCIDAX.a" \
        "$STAGING/$arch/libidax.a" \
        "$STAGING/$arch/libidax_shim.a"
done

# Step 3b: Compile IDA SDK data symbol stubs and add to each libCIDAX.a
STUBS_SRC="$SWIFT_DIR/Sources/CIDAX/shim.c"
for arch in arm64 x86_64; do
    cc -arch "$arch" -c "$STUBS_SRC" -o "$STAGING/$arch/ida_stubs.o"
    ar r "$STAGING/$arch/libCIDAX.a" "$STAGING/$arch/ida_stubs.o"
    rm -f "$STAGING/$arch/ida_stubs.o"
done

# Step 4: Create fat binary
echo "--- Creating universal binary ---"
lipo -create \
    "$STAGING/arm64/libCIDAX.a" \
    "$STAGING/x86_64/libCIDAX.a" \
    -output "$STAGING/universal/libCIDAX.a"

# Step 5: Prepare headers
cp "$SWIFT_DIR/Sources/CIDAX/include/idax_shim.h" "$STAGING/headers/"
cat > "$STAGING/headers/module.modulemap" <<'MODULEMAP'
module CIDAX {
    header "idax_shim.h"
    export *
}
MODULEMAP

# Step 6: Create XCFramework
echo "--- Creating XCFramework ---"
rm -rf "$OUTPUT_DIR/CIDAX.xcframework"
mkdir -p "$OUTPUT_DIR"
xcodebuild -create-xcframework \
    -library "$STAGING/universal/libCIDAX.a" \
    -headers "$STAGING/headers" \
    -output "$OUTPUT_DIR/CIDAX.xcframework"

# Cleanup
rm -rf "$STAGING"

echo "==> CIDAX.xcframework ready at $OUTPUT_DIR/CIDAX.xcframework"
echo "    Architectures: arm64 x86_64"
lipo -info "$OUTPUT_DIR/CIDAX.xcframework/macos-arm64_x86_64/libCIDAX.a" 2>/dev/null || true
```

**Step 2: Make executable and test**

Run: `chmod +x bindings/swift/scripts/build-xcframework.sh && bindings/swift/scripts/build-xcframework.sh`
Expected: `bindings/swift/Frameworks/CIDAX.xcframework/` exists with `Info.plist`, `libCIDAX.a`, headers, and modulemap.

**Step 3: Verify XCFramework contents**

Run: `ls -R bindings/swift/Frameworks/CIDAX.xcframework/`
Expected:
```
Info.plist
macos-arm64_x86_64/
macos-arm64_x86_64/Headers/
macos-arm64_x86_64/Headers/idax_shim.h
macos-arm64_x86_64/Headers/module.modulemap
macos-arm64_x86_64/libCIDAX.a
```

Run: `lipo -info bindings/swift/Frameworks/CIDAX.xcframework/macos-arm64_x86_64/libCIDAX.a`
Expected: `Architectures in the fat file: ... are: x86_64 arm64`

Run: `nm bindings/swift/Frameworks/CIDAX.xcframework/macos-arm64_x86_64/libCIDAX.a | grep '_callui' | head -2`
Expected: shows both `D _callui` (stub definition) and `U _callui` (libidax.a reference)

**Step 4: Commit**

```bash
git add bindings/swift/scripts/build-xcframework.sh
git commit -s -m "feat(swift): add build-xcframework.sh for XCFramework packaging"
```

---

### Task 3: Update Package.swift with dual-mode CIDAX

**Files:**
- Modify: `Package.swift`

**Step 1: Rewrite Package.swift**

```swift
// swift-tools-version: 6.2
import PackageDescription
import Foundation

// IDAX_DEV=1 swift build  → developer mode (link pre-built .a files)
// swift build              → consumer mode (use XCFramework)
let devMode = ProcessInfo.processInfo.environment["IDAX_DEV"] != nil

let libDir: String = {
    if let dir = ProcessInfo.processInfo.environment["IDAX_LIB_DIR"] {
        return dir
    }
    let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    return "\(packageDir)/bindings/swift/.build-libs"
}()

let cidaxTarget: Target = devMode
    ? .target(
        name: "CIDAX",
        path: "bindings/swift/Sources/CIDAX",
        publicHeadersPath: "include",
        cSettings: [
            .headerSearchPath("include"),
        ],
        linkerSettings: [
            .unsafeFlags([
                "-L\(libDir)",
                "-lidax", "-lidax_shim",
            ]),
        ]
    )
    : .binaryTarget(
        name: "CIDAX",
        path: "bindings/swift/Frameworks/CIDAX.xcframework"
    )

let package = Package(
    name: "IDAX",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "IDAX", targets: ["IDAX"]),
    ],
    targets: [
        cidaxTarget,
        .target(
            name: "IDAX",
            dependencies: ["CIDAX"],
            path: "bindings/swift/Sources/IDAX",
            swiftSettings: [
                .enableExperimentalFeature("SafeInteropWrappers"),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "-Xlinker", "-undefined",
                    "-Xlinker", "dynamic_lookup",
                ]),
            ]
        ),
        .testTarget(
            name: "IDAXTests",
            dependencies: ["IDAX"],
            path: "bindings/swift/Tests/IDAXTests"
        ),
    ]
)
```

**Step 2: Test consumer mode**

Prerequisite: Task 2 completed (CIDAX.xcframework exists).

Run: `swift build`
Expected: builds successfully using the XCFramework

Run: `swift test`
Expected: all 40 tests pass

**Step 3: Test developer mode**

Run: `IDAX_DEV=1 swift build`
Expected: builds successfully using pre-built .a files

Run: `IDAX_DEV=1 swift test`
Expected: all 40 tests pass

**Step 4: Commit**

```bash
git add Package.swift
git commit -s -m "feat(swift): dual-mode Package.swift with IDAX_DEV env switch"
```

---

### Task 4: Add .gitignore entries and update CLAUDE.md

**Files:**
- Modify: `.gitignore`
- Modify: `CLAUDE.md`

**Step 1: Add gitignore entries**

Add to `.gitignore`:
```
bindings/swift/.xcframework-staging/
bindings/swift/.cmake-build-*/
```

Note: do NOT gitignore `bindings/swift/Frameworks/` — the XCFramework is committed (approach B from design).

**Step 2: Update CLAUDE.md Swift build commands**

Update the Swift Bindings section to document both modes:

```markdown
### Swift Bindings

\```bash
# Pre-build C++ libraries (developer mode, requires IDASDK)
bindings/swift/scripts/build-libs.sh

# Build XCFramework (creates universal arm64+x86_64 package)
bindings/swift/scripts/build-xcframework.sh

# Build — consumer mode (uses XCFramework)
swift build

# Build — developer mode (uses pre-built .a files)
IDAX_DEV=1 swift build

# Test
swift test
\```
```

**Step 3: Commit**

```bash
git add .gitignore CLAUDE.md
git commit -s -m "docs: update build instructions for XCFramework dual-mode"
```
