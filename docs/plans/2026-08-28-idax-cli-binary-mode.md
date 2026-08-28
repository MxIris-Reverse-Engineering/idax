# idax Command-Line Tool: Single-Binary Mode Implementation Plan

**Goal:** Teach the Swift command-line tool to create a database from a single Mach-O binary, selecting the fat slice that matches the host architecture by default, and rename the tool from `idax-dyld-cache-database-creator` to `idax`.

**Architecture:** Four layers. `ida::database` gains the ability to enumerate the loaders IDA would offer for an input file and to name one when opening. The shared C shim (`bindings/rust/idax-sys/shim/idax_shim.cpp`, declared in `bindings/c/include/idax_shim.h`, consumed by both Rust and Swift) exposes those two operations. The Swift wrapper reflects them. The tool splits into two subcommands and adds architecture resolution on top.

**Tech Stack:** C++23, the existing C ABI, Swift 6.2 tools with `MainActor` default isolation, swift-argument-parser 1.8.2, swift-testing.

---

## Background: what the IDA runtime actually does

Measured against `<ida-runtime>` from IDA Professional 9.4, using `ctypes` against `libidalib.dylib` and `libida.dylib` directly — no idax code involved, so these are properties of IDA, not of this repository.

**A fat Mach-O reaches IDA as several candidate loaders, and unattended IDA takes the first.**
`build_loaders_list()` returns one `load_info_t` per slice:

| Input | `ftypename` values, in list order | `processor` |
|---|---|---|
| thin arm64 | `Mach-O file (EXECUTE). ARM64` | `arm` |
| fat x86_64 + arm64 | `Fat Mach-O file, 1. X86_64`, `Fat Mach-O file, 2. ARM64` | `metapc`, `arm` |
| fat arm64 + arm64e | `Fat Mach-O file, 1. ARM64`, `Fat Mach-O file, 2. ARM64e-pauth1` | `arm`, `arm` |

`lipo` orders slices by CPU type, which puts x86_64 ahead of arm64 in every universal binary Apple's toolchain produces. That is the whole of the reported bug: IDA logs `Detected file format: Fat Mach-O file, 1. X86_64` and analyses the wrong architecture.

**`open_database()` accepts IDA command-line arguments, and `-T` selects the loader.**
The third parameter of `open_database(const char *file_path, bool run_auto, const char *args)` is documented in `<ida-sdk-root>/src/include/idalib.hpp` as "optional arguments, respecting IDA's command-line arguments format". Passing `-T"Fat Mach-O file, 2. ARM64e-pauth1"` produced `Detected file format: Fat Mach-O file, 2. ARM64e-pauth1` and a return code of 0.

**The quoting is load-bearing.** `args` is split on whitespace before parsing. Passing the same value unquoted — `-TFat Mach-O file, 2.` — makes `open_database` return 1 with `Database initialization failed with error 1`. Single and double quotes both work; the quotes must be inside the C string.

**`ftypename` is exactly the string `-T` expects.** It carries its own `N.` ordinal, so round-tripping a list entry back into `-T` needs no parsing, no ordinal arithmetic, and no prefix truncation. Verified by feeding the full `Fat Mach-O file, 2. ARM64e-pauth1` back and getting that exact slice.

**arm64e format names carry a pointer-authentication ABI version suffix** (`ARM64e-pauth1`) that tracks the slice's CPU subtype. Any design that matches architecture names literally has to treat this as a prefix, not an equality test.

---

## Locked decisions

**Slice selection goes through IDA's own loader list.** `ida::database::list_input_formats()` wraps `open_linput` + `build_loaders_list` + `free_loaders_list` and returns the `ftypename` strings verbatim. The tool picks one and hands the same string back through `-T`. Ordinals are never computed on this side, so there is no way for our numbering to disagree with IDA's.

**`OpenOptions` carries the format name, not a raw argument string.** The public surface is `struct OpenOptions { OpenMode mode; std::string file_type; }`; the `-T` flag and its quoting are an implementation detail of `database_lifecycle.cpp`. Exposing an "extra arguments" passthrough would be an escape hatch into IDA's command line, which decision 3 in `agents.md` rules out.

**Architecture is parsed off the tail of the format name, arm64e before arm64.** The substring after the last `". "` is the architecture token: `ARM64`, `ARM64e-pauth1`, `X86_64`. Matching is case-insensitive and prefix-based, and **`arm64e` must be tested before `arm64`**, since the former has the latter as a prefix. This is a pure function and is unit-tested directly against the three measured token shapes.

**Host architecture with arm64 preferred over arm64e.** On an arm64 host the tool takes `arm64` when present, `arm64e` otherwise. On an x86_64 host it takes `x86_64`. `--arch` overrides the default and accepts `arm64`, `arm64e`, `x86_64`.

**No match is an error, not a fallback.** When the input is fat and offers neither the requested nor the host architecture, the tool fails and lists what the file does contain. Silently substituting a slice is the failure mode this entire change exists to remove; making it quieter would defeat the purpose.

**Inputs with a single candidate open unmodified.** A thin Mach-O, an ELF, or a PE yields one loader; the tool opens it without `-T` and lets IDA do what it already does correctly. An explicit `--arch` that contradicts a single-candidate input is an error, so `--arch` never silently does nothing.

**Two subcommands under one root.** `idax dyld-cache` keeps every flag the current tool has, byte for byte; `idax binary` is new. The shared output flags (`--output`, `--overwrite`, `--skip-final-analysis`) are declared once and reused.

**Scope stops at Swift.** C++, the C shim, the Swift wrapper, and the tool. The shim is shared with Rust, so Rust's `idax-sys` gets the entry points for free, but the Rust safe layer and the Node addon are not wrapped in this change; that is recorded as follow-up work rather than done silently.

---

## Rejected alternatives

**Parsing the fat header ourselves.** The tool could read `fat_header` / `fat_arch` and compute a slice ordinal. It is less code in the immediate sense and it introduces exactly the class of bug being fixed: if IDA ever skips a slice it cannot load, our ordinal and IDA's disagree and the tool silently selects the wrong architecture with full confidence. Asking IDA what it is willing to load cannot drift from what IDA then loads.

**Extracting the slice with `lipo -thin` before handing it to IDA.** Sidesteps loader selection entirely and needs no C++ change at all. Rejected because it makes every database's input path point at a temporary file, which corrupts `input_file_path()`, the input MD5, and any downstream tooling that re-resolves the original binary. It also costs a full file copy per invocation.

**Driving `idat -T` as a subprocess.** Works today, verified. Rejected on the user's instruction — the point of this tool is to not shell out to the official binaries.

**Matching architecture names for equality.** `ARM64e-pauth1` is not `arm64e`, and the suffix version will change as Apple's pointer-authentication ABI moves. Prefix matching is the only stable form.

**Keeping `idax-dyld-cache-database-creator` as an alias product.** The tool is this fork's own and has no external consumers; carrying a second product name would preserve a name that describes half of what the tool does.

**Passing `run_auto = true` for the binary subcommand.** The dyld cache path deliberately opens with analysis off and drains the queue explicitly, so failures surface at a known point. The binary path follows the same shape rather than inventing a second lifecycle.

---

## Task 1: C++ core

Files: `include/ida/database.hpp`, `src/database_lifecycle.cpp`, `tests/unit/api_surface_parity_test.cpp`.

1. Add `struct InputFormat { std::string name; std::string processor; std::string loader_path; bool archive_loader; }`. The SDK's `filetype_t` value is deliberately **not** exposed — it is an SDK enum, and decision 3 forbids SDK types on the public surface.
2. Add `Result<std::vector<InputFormat>> list_input_formats(std::string_view path)`, implemented with `open_linput` / `build_loaders_list` / `free_loaders_list` / `close_linput`, with the list freed on every exit path.
3. Add `struct OpenOptions { OpenMode mode = OpenMode::Analyze; std::string file_type; }` and `Status open(std::string_view path, const OpenOptions& options)`. When `file_type` is non-empty, build `-T"<file_type>"` and pass it as `open_database`'s third argument; when empty, pass `nullptr` so existing behaviour is bit-identical.
4. Reject a `file_type` containing a double quote with a `Validation` error rather than emitting a malformed argument string.
5. Make the existing `open_binary` / `open_non_binary` stubs delegate through `OpenOptions` instead of silently forwarding, so their comments stop claiming something they do not do.

**Acceptance:** `list_input_formats` on the fat fixture returns two entries whose names match the measured strings; opening with the second entry's name reports that format from `database::file_type_name()`; opening with an empty `OpenOptions` is unchanged.

## Task 2: C shim and Swift wrapper

Files: `bindings/c/include/idax_shim.h`, `bindings/rust/idax-sys/shim/idax_shim.cpp`, `bindings/swift/Sources/IDAX/Database.swift`.

1. `typedef struct IdaxDatabaseInputFormat { char* name; char* processor; char* loader_path; int archive_loader; }`, plus `idax_database_list_input_formats(const char* path, IdaxDatabaseInputFormat** out, size_t* count)` and `idax_database_input_formats_free(...)`, following the allocation and partial-failure-cleanup pattern already used by `idax_database_import_modules`.
2. `idax_database_open_with_options(const char* path, int mode, const char* file_type)`, with `file_type == nullptr` meaning "let IDA choose".
3. Swift: `public struct InputFormat: Sendable`, `Database.listInputFormats(_:)`, `Database.OpenOptions`, and `Database.open(_:options:)`. Existing `open` overloads stay.

**Acceptance:** `IDAX_DEV=1 swift build` clean; a Swift integration test lists formats for the fat fixture and opens the non-default slice.

## Task 3: Rename and split, with no behaviour change

Moves only — reviewable as a rename, so the behaviour change in Task 4 lands against a clean baseline.

- `bindings/swift/Tools/DyldCacheDatabaseCreatorCore` → `bindings/swift/Tools/CommandLineCore`
- `bindings/swift/Tools/DyldCacheDatabaseCreator` → `bindings/swift/Tools/CommandLine`
- `bindings/swift/Tests/IDAXDyldCacheDatabaseCreatorTests` → `bindings/swift/Tests/IDAXCommandLineTests`
- Targets `IDAXDyldCacheDatabaseCreatorCore` / `IDAXDyldCacheDatabaseCreator` / `IDAXDyldCacheDatabaseCreatorTests` → `IDAXCommandLineCore` / `IDAXCommandLine` / `IDAXCommandLineTests`
- Product `idax-dyld-cache-database-creator` → `idax`
- New root `IDAXCommand` with `subcommands: [DynamicLinkerSharedCacheDatabaseCreator.self]`; the existing type keeps its name and implementation, and its `commandName` becomes `dyld-cache`.

**Acceptance:** `swift test` passes with only the import line changed in the test file; `swift run idax dyld-cache --help` shows the same flags as before.

## Task 4: The `binary` subcommand

Files: `bindings/swift/Tools/CommandLineCore/MachOArchitecture.swift`, `.../BinaryDatabaseCreator.swift`, `bindings/swift/Tests/IDAXCommandLineTests/MachOArchitectureTests.swift`.

1. `MachOArchitecture` as a `RawRepresentable` string wrapper with `.arm64`, `.arm64e`, `.x86_64`, a `current` derived from `#if arch(...)`, and `preferenceOrder` expressing arm64-before-arm64e.
2. `MachOArchitecture.init?(formatName:)` — the pure parse described under locked decisions, unit-tested against `Fat Mach-O file, 1. X86_64`, `Fat Mach-O file, 2. ARM64`, `Fat Mach-O file, 2. ARM64e-pauth1`, and `Mach-O file (EXECUTE). ARM64`, including the arm64e-before-arm64 ordering case.
3. `resolveInputFormat(candidates:requested:)` — pure, returns the chosen format or a typed failure carrying the available architectures for the error message.
4. `BinaryDatabaseCreator`: validate, initialize, list, resolve, open with the resolved format name, drain analysis unless `--skip-final-analysis`, save, close.

**Acceptance:** unit tests cover the parse and resolution functions with no IDA runtime; a fixture-backed integration test creates an arm64 database from a universal binary and asserts `Database.processorName()` is the ARM module, not `metapc`.

## Task 5: Documentation and records

- `docs/Tools/` gains a page for the renamed tool covering both subcommands and the architecture rules.
- `.agents/fork/roadmap.md`, `.agents/fork/progress_ledger.md`, `.agents/fork/decision_log.md` (the loader-list decision and its rejected alternatives), and `.agents/fork/findings.md` + `.agents/fork/knowledge_base.md` (the four measured IDA behaviours in Background) — all under `F`-prefixed numbering.
- `.agents/fork/active_work.md` records the unwrapped Rust safe layer and Node addon as follow-up.

---

## Verification

1. `cmake --build build && ctest --test-dir build -R "idax_unit_test|api_surface_parity"` — C++ core.
2. `IDAX_DEV=1 swift build && swift test` — Swift wrapper and tool, with unit tests running without an IDA runtime.
3. Manual end-to-end against a universal binary: `swift run idax binary <universal>` produces an arm64 database; `--arch x86_64` produces an x86_64 one; a fat file lacking the host architecture fails with the architecture list.
4. `swift run idax dyld-cache ...` reproduces a database the current tool already produces.

---

## Risks

**The packaged XCFramework goes further out of date.** `bindings/swift/Frameworks/CIDAX.xcframework` already lags the C ABI badly (785 symbols against 1066) and consumer mode cannot reach the new entry points until it is rebuilt. Developer mode is unaffected, which is what the tool uses. Rebuilding it belongs to the parity plan dated 2026-08-27, not here.

**`ftypename` is an IDA-internal display string.** Round-tripping it is exact today and the SDK offers no more stable identifier for a fat slice, but the strings could change between IDA versions. The architecture parse is prefix-based and centralised in one function specifically so a version bump is a one-place fix. Measured on 9.4 only.

**Uncommitted concurrency work is in flight.** The working tree carries the module-wide `MainActor` isolation change from the 2026-08-27 parity plan, including edits to `Package.swift`, which Task 3 also modifies. Task 3 must rebase onto whatever that work settles at rather than racing it.

**`init_library` must precede `list_input_formats`.** `build_loaders_list` needs a live IDA runtime. The tool already calls `Database.initialize()` first; the C++ function documents the requirement and the shim surfaces IDA's failure rather than crashing.
