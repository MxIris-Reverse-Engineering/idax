# Dyld Cache Database Creator

`idax-dyld-cache-database-creator` is a macOS command-line tool that creates an
IDA database from selected images in a dyld shared cache. It uses the IDAX
Swift API for database lifecycle, dyld cache image loading, optional region
loading, analysis control, and explicit output-path saving.

## Requirements

- macOS 13 or newer.
- IDA Professional with idalib support. The current validated runtime is IDA
  Professional 9.3.
- `IDADIR` pointing to the IDA runtime directory when IDA is not discoverable
  automatically.

```bash
export IDADIR="/Applications/IDA Professional 9.3.app/Contents/MacOS"
```

## Build and run

The executable is a Swift Package product and uses
[`swift-argument-parser`](https://github.com/apple/swift-argument-parser).

```bash
swift package update
swift build --product idax-dyld-cache-database-creator
swift run idax-dyld-cache-database-creator --help
```

Create a database containing three images:

```bash
swift run idax-dyld-cache-database-creator \
  --cache /Volumes/DyldSharedCaches/macOS/26.5.2_25F84/dyld_shared_cache_arm64e \
  --image-name AppKit SwiftUI SwiftUICore
```

`--image-name` accepts a space-separated list. Each name is matched exactly
against the final component of every cache image path after removing its file
extension. For example, `libobjc.A` matches `/usr/lib/libobjc.A.dylib`.

Images can instead be selected by complete cache paths:

```bash
swift run idax-dyld-cache-database-creator \
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

Use `--output` to select the output path:

```bash
swift run idax-dyld-cache-database-creator \
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
| `--load-dyld-header` | Wait for the required initial analysis, then load and format the dyld cache header. |
| `--load-branch-islands` | Load every branch-island region. |
| `--load-branch-mappings` | Load every branch-mapping region. |
| `--load-global-offset-tables`, `--load-got` | Load every global offset table region. |
| `--load-gaps`, `--load-gap` | Load every gap region. |

Image and optional-region operations enqueue auto-analysis without waiting after
each call. By default the tool drains the queue once before saving. Use
`--skip-final-analysis` for a faster database creation pass when downstream work
does not require a quiescent analysis state.

## Lifecycle behavior

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
