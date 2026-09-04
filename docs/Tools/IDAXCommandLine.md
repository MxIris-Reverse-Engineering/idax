# The `idax` command-line tool

`idax` is a macOS command-line tool that creates IDA databases headlessly. It
uses the IDAX Swift API for database lifecycle, loading, analysis control, and
explicit output-path saving.

| Subcommand | Purpose |
|---|---|
| `idax binary` | Create a database from a single binary, selecting the architecture slice |
| `idax dyld-cache` | Create a database from selected dyld shared cache images |
| `idax formats` | List the slices and loaders IDA offers for a file |

## Requirements

- macOS 13 or newer.
- IDA Professional with idalib support. The committed framework and current
  validated runtime use IDA Professional 9.4.
- `IDADIR` pointing to the IDA runtime directory when IDA is not discoverable
  automatically.

```bash
export IDADIR="/Applications/IDA Professional 9.4.app/Contents/MacOS"
```

The C++ source remains build-compatible with IDA SDK 9.3. A distributed
`CIDAX.xcframework` should be built with the SDK matching the destination IDA
runtime; it does not bundle IDA or an IDA license. IDA 9.4 builds use the public
`dscu_svc_t` service, while IDA 9.3 builds retain the legacy dscu compatibility
backend. Cache-wide data regions are available only in IDA 9.4.

## Build and run

The executable is a Swift Package product and uses
[`swift-argument-parser`](https://github.com/apple/swift-argument-parser).

To build and install it for the current user:

```bash
./scripts/install_idax_command_line.sh
idax --help
```

By default, the installer places the launcher in `~/.local/bin` and the
executable plus `CIDAX.framework` in
`~/.local/libexec/idax`. If `~/.local/bin` is not
already on `PATH`, the installer adds it to `~/.zshrc` for new terminal
sessions. Set `IDAX_INSTALLATION_PREFIX` to select a different user-writable
installation prefix.

For a repository-local build instead:

```bash
swift package update
swift build --product idax
swift run idax --help
```

## `idax binary` — a single binary

```bash
idax binary /path/to/UniversalApp
idax binary --arch x86_64 /path/to/UniversalApp
idax binary /path/to/App --output /tmp/App --overwrite
```

### Architecture selection

A universal ("fat") Mach-O contains several architecture slices. IDA running
unattended loads the *first* one, and `lipo` orders slices by CPU type, which
puts x86_64 ahead of arm64 in everything Apple's toolchain builds — so an
unattended IDA analyses the x86_64 slice of an arm64 application.

`idax binary` instead selects the slice matching the host architecture,
preferring `arm64` over `arm64e` when a file offers both. `--arch` overrides
this and accepts `arm64`, `arm64e`, or `x86_64`.

A file that offers neither the requested nor the host architecture is an error
naming what it does contain:

```
error: The input does not contain arm64. It contains: x86_64, i386.
       Pass --arch to select one explicitly.
```

Substituting a different slice would reproduce the very failure this
subcommand exists to remove, so it is never done silently. `--arch` on an input
that is not a universal binary is likewise an error rather than a silent no-op.

After the database opens, the tool re-reads the format IDA actually loaded and
fails without saving if it is not the architecture that was selected. Non-fat
inputs — a thin Mach-O, an ELF, a PE — are opened with IDA's own detection
untouched.

### Options

| Option | Effect |
|---|---|
| `--arch <name>` | Architecture to load: `arm64`, `arm64e`, `x86_64`. Defaults to the host's |
| `--output <path>` | Output database path; a missing extension is completed with `.i64` |
| `--overwrite` | Replace an existing output database |
| `--skip-final-analysis` | Save without draining the final auto-analysis queue |

Without `--output`, the database is named after the input file with `.i64` in
the current directory.

## `idax formats` — what IDA sees

```bash
idax formats /path/to/UniversalApp
```

```
Universal binary with 2 slices:
  1. arm64
  2. arm64e
IDA loaders:
  Fat Mach-O file, 1. ARM64  [processor: arm]
  Fat Mach-O file, 2. ARM64e-pauth1  [processor: arm]
Host architecture: arm64
`idax binary` would select: arm64 (slice 1)
```

No database is created. This is the diagnostic to reach for when `idax binary`
reports that it could not confirm the loaded architecture.

## `idax dyld-cache` — shared cache images

Create a database containing three images:

```bash
swift run idax dyld-cache \
  --cache /Volumes/DyldSharedCaches/macOS/26.5.2_25F84/dyld_shared_cache_arm64e \
  --image-name AppKit SwiftUI SwiftUICore
```

`--image-name` accepts a space-separated list. Each name is matched exactly
against the final component of every cache image path after removing its file
extension. For example, `libobjc.A` matches `/usr/lib/libobjc.A.dylib`.

Images can instead be selected by complete cache paths:

```bash
swift run idax dyld-cache \
  --cache /path/to/dyld_shared_cache_arm64e \
  --image-path \
    /System/Library/Frameworks/AppKit.framework/Versions/C/AppKit \
    /System/Library/PrivateFrameworks/UIKitMacHelper.framework/Versions/A/UIKitMacHelper
```

Both selectors accept lists and can be combined. Name selections are resolved
first, followed by explicit path selections. If multiple paths have the same
derived name, the first path in cache enumeration order is selected; use
`--image-path` to select a different one. Missing paths, missing names, and
selectors that resolve to duplicate images are rejected. IDA's Mach-O loader
selects the first resolved image while IDAX loads every additional image
through `DyldCache.loadModule`.

## Output naming

These rules apply to `idax dyld-cache`; `idax binary` names its default output
after the input file instead. Use `--output` to select the output path:

```bash
swift run idax dyld-cache \
  --cache /path/to/dyld_shared_cache_arm64e \
  --image-name AppKit \
  --output /tmp/SystemInterface
```

A missing extension is completed with `.i64`; an explicit extension is
preserved. Without `--output`, the tool joins every derived image name (the
final path component without its extension) with `+` and adds `.i64`. For
example, `AppKit` and `UIKitMacHelper` produce
`AppKit+UIKitMacHelper.i64` in the current directory.

An existing output is rejected unless `--overwrite` is present. Replacement is
deferred until all requested cache content has loaded successfully, so a failed
load does not remove the previous database. The output path cannot be the cache
itself or a directory, even when `--overwrite` is present.

## Optional cache regions

The tool supports these independent flags:

| Option | Effect |
|---|---|
| `--load-dyld-header` | Load and format the dyld cache header on IDA 9.3. IDA 9.4 loads it initially, so this flag is idempotent. |
| `--load-branch-islands` | Load every branch-island region. |
| `--load-branch-mappings` | Load every branch-mapping region. |
| `--load-global-offset-tables`, `--load-got` | Load every global offset table region. |
| `--load-unknown-regions`, `--load-unknown-region`, `--load-gaps`, `--load-gap` | Load every covered but unidentified region. IDA 9.3 called these gaps. |
| `--load-cache-data` | Load every cache-wide named data region, such as linkedit subcache mappings. Requires IDA 9.4. |

Image and optional-region operations enqueue auto-analysis without waiting after
each call. By default the tool drains the queue once before saving. Use
`--skip-final-analysis` for a faster database creation pass when downstream work
does not require a quiescent analysis state.

## Lifecycle behavior

### Why the architecture is chosen before IDA starts

IDA accepts an input format only on its initialisation call — `idat` is a thin
shell over `init_library(argc, argv)`, and the whole IDA command line is parsed
there. Two consequences shape `idax binary`:

- IDA's own loader list (`Database.listInputFormats(_:)`) cannot inform the
  choice. Building it requires an initialised library, and by then the format
  is already fixed; re-initialising to change it does not work. So the slice is
  derived from the file's fat header before IDA starts, and the result is
  verified against IDA once the database is open.
- `open_database`'s argument string also accepts a format and must not be used
  for it. A database opened that way saves correctly but cannot be closed
  cleanly on IDA 9.4, leaving unpacked `.id0`/`.id1`/`.nam`/`.til` files beside
  the input. `RuntimeOptions.inputFormat` therefore carries the format into
  initialisation, which is both the working path and the honest one.

### Dyld cache loading

The tool first enumerates the cache directly with `DyldCache.listModules(in:)`
so image names can be resolved before a database exists. It temporarily sets
`IDA_DYLD_CACHE_MODULE` to the first resolved path and
`IDA_DYLD_CACHE_DEPTH` to `0`, then restores both variables to their original
values before exiting. It opens the raw cache without an immediate analysis
wait, loads the requested content, saves through `Database.save(to:)`, and
closes without a second implicit save.

The underlying C++ API is `ida::database::save_to`; the same operation is
available as `Database.save(to:)` in Swift, `database.saveTo` in Node, and
`database::save_to` in Rust.

IDA 9.4 image and region loading is routed through the supported service from
`dscu.h`. IDA 9.3 source builds route the same IDAX API through the older dscu
plugin protocol. See [IDA 9.4 Dyld Cache Adaptation](../IDA94DyldCacheAdaptation.md)
for the compatibility model and migration notes.
