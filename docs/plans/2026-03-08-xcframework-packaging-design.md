# XCFramework Packaging Design

## Goal

Package `libidax.a` + `libidax_shim.a` into a single `CIDAX.xcframework` so that
Swift consumers can use the IDAX package without running `build-libs.sh` manually.
Support macOS arm64 + x86_64 as a universal (fat) binary.

## Scripts

### `build-libs.sh` (modify existing)

Add `--arch <arch>` parameter and `--output-dir <dir>` support.  When `--arch` is
specified, pass `-DCMAKE_OSX_ARCHITECTURES=<arch>` to CMake and the corresponding
`-arch` flag to the shim compilation.  Default behaviour (no flag) remains unchanged
for backwards compatibility.

### `build-xcframework.sh` (new)

Orchestrates the full XCFramework build:

1. Call `build-libs.sh --arch arm64 --output-dir .build-libs/arm64`
2. Call `build-libs.sh --arch x86_64 --output-dir .build-libs/x86_64`
3. Per architecture: `libtool -static` merges `libidax.a` + `libidax_shim.a` → `libCIDAX.a`
4. `lipo -create` merges both architectures into a fat `libCIDAX.a`
5. Generate `module.modulemap` for the CIDAX module
6. `xcodebuild -create-xcframework -library libCIDAX.a -headers include/ -output CIDAX.xcframework`
7. Output to `bindings/swift/Frameworks/CIDAX.xcframework`

## Package.swift

Environment variable `IDAX_DEV` switches between developer and consumer modes:

- `IDAX_DEV=1 swift build` → developer mode: CIDAX is a regular `.target` with
  `unsafeFlags` linking pre-built `.a` files (current behaviour)
- `swift build` → consumer mode: CIDAX is a `.binaryTarget(path:)` pointing to
  the local XCFramework

In consumer mode, `-Xlinker -undefined -Xlinker dynamic_lookup` and
`.linkedLibrary("c++")` move to the IDAX Swift target's `linkerSettings`, since
`.binaryTarget` does not support linker settings.

## XCFramework Structure

```
CIDAX.xcframework/
├── Info.plist
└── macos-arm64_x86_64/
    ├── libCIDAX.a              (fat: arm64 + x86_64)
    └── Headers/
        ├── idax_shim.h
        └── module.modulemap
```

### module.modulemap

```
module CIDAX {
    header "idax_shim.h"
    export *
}
```

## Constraints

- `-undefined dynamic_lookup` forces flat namespace; IDA SDK data symbol stubs
  (`callui`, `dbg`, `under_debugger`) are provided by `CIDAX/shim.c` in dev mode.
  In consumer mode the stubs must be inside `libCIDAX.a` — the `build-xcframework.sh`
  script compiles `shim.c` and includes it in the merged static library.
- Future migration to GitHub Releases: change `.binaryTarget(path:)` to
  `.binaryTarget(url:, checksum:)` and add `swift package compute-checksum` to the
  build script.
