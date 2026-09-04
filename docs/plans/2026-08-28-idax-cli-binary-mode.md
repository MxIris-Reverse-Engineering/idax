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

**But `open_database`'s `args` is the wrong channel entirely.** A database opened that way selects the right slice and saves correctly, then aborts on *any* form of teardown with `FATAL ERROR: Oops! internal error 30500 occurred.`, leaving `.id0`/`.id1`/`.nam`/`.til` unpacked files beside the input — a database that was never closed cleanly. `close_database(false)`, `close_database(true)` and the SDK sample's `set_database_flag(DBFL_KILL) + term_database()` all reproduce it. lldb puts the abort inside `_ida_hexrays.so`. It reproduces against the bare SDK with no idax linked, and on a thin Mach-O given `-T` as well, so it is neither an idax problem nor a fat-file problem.

**`init_library(argc, argv)` is the right channel, and `idat` shows why.** Disassembling `idat` (33 KB) shows its entire `start` is a forwarder:

```c
__int64 start(int argc, _QWORD *argv) {
  if (argc != 1) { v3 = init_library(argc, argv); ... qexit(v3); }
  return init_library(2, (_QWORD[]){argv[0], "--help"});
}
```

IDA's whole command line is parsed by `init_library`. Passing `-T` there selects the slice *and* tears down cleanly: exit code 0, no residue. No quoting is needed in the argv form — `-T` and its value are one argv entry; only the command-line *string* form needs quotes, because IDA splits that on whitespace.

**The format must be on the single initialisation call.** `build_loaders_list` before `init_library` segfaults, and initialising twice — once bare to list candidates, once with `-T` — returns 0 both times and still reproduces the teardown abort. So IDA's own loader list cannot inform the choice of format.

**`ftypename` is exactly the string `-T` expects.** It carries its own `N.` ordinal, so round-tripping a list entry back into `-T` needs no parsing, no ordinal arithmetic, and no prefix truncation. Verified by feeding the full `Fat Mach-O file, 2. ARM64e-pauth1` back and getting that exact slice.

**arm64e format names carry a pointer-authentication ABI version suffix** (`ARM64e-pauth1`) that tracks the slice's CPU subtype. Any design that matches architecture names literally has to treat this as a prefix, not an equality test.

---

## Locked decisions

**The format is a runtime option, not an open option.** `RuntimeOptions::input_format` carries the format name and `init` turns it into a `-T` argv entry. It reads as belonging to `open()`, and `open_database` even accepts it there, but that path cannot be torn down (see Background). The `-T` spelling stays an implementation detail of `database_lifecycle.cpp`; no raw argument passthrough is exposed, which decision 3 in `agents.md` rules out anyway.

**The slice is chosen from the fat header and verified against IDA afterwards.** `list_input_formats()` is the better source and is unusable for the choice: it needs an initialised library, and the format must already be set on that one initialisation call. So `MachOFatHeader` derives the ordinal from the file, the tool passes `Fat Mach-O file, N.`, and after opening it re-reads `get_file_type_name()` and fails loudly if the architecture is not the one selected. Deriving the ordinal assumes IDA numbers candidates in file order — true for every binary measured, but a slice IDA declines to load would shift it, and a silently wrong architecture is the exact failure this tool exists to remove.

**The `-T` value carries a trailing dot.** IDA prefix-matches, so `Fat Mach-O file, 1` would also match `Fat Mach-O file, 10. …` in a binary with ten or more slices.

**Architecture is parsed off the tail of the format name, arm64e before arm64.** The substring after the last `". "` is the architecture token: `ARM64`, `ARM64e-pauth1`, `X86_64`. Matching is case-insensitive and prefix-based, and **`arm64e` must be tested before `arm64`**, since the former has the latter as a prefix. This is a pure function and is unit-tested directly against the three measured token shapes.

**Host architecture with arm64 preferred over arm64e.** On an arm64 host the tool takes `arm64` when present, `arm64e` otherwise. On an x86_64 host it takes `x86_64`. `--arch` overrides the default and accepts `arm64`, `arm64e`, `x86_64`.

**No match is an error, not a fallback.** When the input is fat and offers neither the requested nor the host architecture, the tool fails and lists what the file does contain. Silently substituting a slice is the failure mode this entire change exists to remove; making it quieter would defeat the purpose.

**Inputs with a single candidate open unmodified.** A thin Mach-O, an ELF, or a PE yields one loader; the tool opens it without `-T` and lets IDA do what it already does correctly. An explicit `--arch` that contradicts a single-candidate input is an error, so `--arch` never silently does nothing.

**Two subcommands under one root.** `idax dyld-cache` keeps every flag the current tool has, byte for byte; `idax binary` is new. The shared output flags (`--output`, `--overwrite`, `--skip-final-analysis`) are declared once and reused.

**Scope stops at Swift.** C++, the C shim, the Swift wrapper, and the tool. The shim is shared with Rust, so Rust's `idax-sys` gets the entry points for free, but the Rust safe layer and the Node addon are not wrapped in this change; that is recorded as follow-up work rather than done silently.

---

## Rejected alternatives

**Choosing the slice from IDA's own loader list.** The original plan, and the better design: ask IDA what it is willing to load, hand the same string back, and our numbering cannot drift from IDA's. It is impossible under the ordering constraint above — the list needs an initialised library and the format must be set on that same initialisation call. Reading the fat header ourselves reintroduces the risk of disagreeing with IDA's numbering, which is why the result is verified after opening rather than trusted.

**Extracting the slice with `lipo -thin` before handing it to IDA.** Sidesteps loader selection entirely and needs no C++ change at all. Rejected because it makes every database's input path point at a temporary file, which corrupts `input_file_path()`, the input MD5, and any downstream tooling that re-resolves the original binary. It also costs a full file copy per invocation.

**Driving `idat -T` as a subprocess.** Works today, verified. Rejected on the user's instruction — the point of this tool is to not shell out to the official binaries.

**Matching architecture names for equality.** `ARM64e-pauth1` is not `arm64e`, and the suffix version will change as Apple's pointer-authentication ABI moves. Prefix matching is the only stable form.

**Keeping `idax-dyld-cache-database-creator` as an alias product.** The tool is this fork's own and has no external consumers; carrying a second product name would preserve a name that describes half of what the tool does.

**Passing `run_auto = true` for the binary subcommand.** The dyld cache path deliberately opens with analysis off and drains the queue explicitly, so failures surface at a known point. The binary path follows the same shape rather than inventing a second lifecycle.

---

## Task 1: C++ core  — done

Files: `include/ida/database.hpp`, `src/database_lifecycle.cpp`, `tests/unit/api_surface_parity_test.cpp`.

1. `struct InputFormat { name; processor; loader_path; archive_loader; }`. The SDK's `filetype_t` is deliberately not exposed — it is an SDK enum, and decision 3 forbids SDK types on the public surface.
2. `Result<std::vector<InputFormat>> list_input_formats(std::string_view)` over `open_linput` / `build_loaders_list` / `free_loaders_list` / `close_linput`, freed on every exit path through RAII guards.
3. `RuntimeOptions::input_format`; `init` appends it to argv as one `-T<format>` entry, preserving any argv the caller passed.
4. `OpenOptions` carries only `mode`. `open_binary` / `open_non_binary` route through it instead of silently forwarding.

## Task 2: C shim and Swift wrapper — done

Files: `bindings/c/include/idax_shim.h`, `bindings/rust/idax-sys/shim/idax_shim.cpp`, `bindings/swift/Sources/IDAX/Database.swift`.

`IdaxDatabaseInputFormat` + `idax_database_list_input_formats` / `..._free` following the `idax_database_import_modules` allocation pattern; `IdaxRuntimeOptions.input_format`; `idax_database_open_with_options(path, mode)`. Swift gets `InputFormat`, `Database.listInputFormats(_:)`, `RuntimeOptions.inputFormat` and `OpenOptions`.

## Task 3: Rename and split — done

Directories, targets and the product renamed to `CommandLine*` / `IDAXCommandLine*` / `idax`; root `IDAXCommand` with `dyld-cache` keeping every flag it had.

## Task 4: The `binary` and `formats` subcommands — done

Files: `MachOArchitecture.swift`, `MachOFatHeader.swift`, `BinaryDatabaseCreator.swift`, `InputFormatLister.swift`, `MachOArchitectureTests.swift`.

`MachOFatHeader` parses the fat header (both 32- and 64-bit forms, capability bits masked off cpusubtype, bounded slice count). `SliceResolver` picks the slice and builds the `-T` value. `BinaryDatabaseCreator` resolves, initialises with the format, opens, verifies via `fileTypeName()`, analyses, saves. `formats` lists what IDA offers, which is what a user needs when that verification fails.

**Acceptance met:** 109 Swift tests and 6 C++ tests pass. The architecture parse and slice resolution were mutation-tested — reversing the arm64e/arm64 order and degrading selection to "first slice" each turned 3 tests red, and both were restored to green.

## Verification

1. `cmake --build build && ctest --test-dir build -R "idax_unit_test|api_surface_parity"` — C++ core.
2. `IDAX_DEV=1 swift build && swift test` — Swift wrapper and tool, with unit tests running without an IDA runtime.
3. Manual end-to-end against a universal binary: `swift run idax binary <universal>` produces an arm64 database; `--arch x86_64` produces an x86_64 one; a fat file lacking the host architecture fails with the architecture list.
4. `swift run idax dyld-cache ...` reproduces a database the current tool already produces.

---

## Risks

**The packaged XCFramework goes further out of date.** `bindings/swift/Frameworks/CIDAX.xcframework` already lags the C ABI badly (785 symbols against 1066) and consumer mode cannot reach the new entry points until it is rebuilt. Developer mode is unaffected, which is what the tool uses. Rebuilding it belongs to the parity plan dated 2026-08-27, not here.

**IDA's format names are internal display strings.** The `-T` ordinal prefix and the architecture parse both depend on the `Fat Mach-O file, N. <ARCH>` shape, which could change between IDA versions. Both are centralised in one function each, and the post-open verification turns a format-name change into a loud failure rather than a wrong-architecture database. Measured on 9.4 only.

**The teardown abort is unreported upstream.** `internal error 30500` has no public documentation and appears in neither the SDK's `err.h` nor `ida.hlp`. A minimal reproducer exists (bare SDK, ~60 lines) should this be worth filing with Hex-Rays.

**Uncommitted concurrency work is in flight.** The working tree carries the module-wide `MainActor` isolation change from the 2026-08-27 parity plan, including edits to `Package.swift`, which Task 3 also modifies. Task 3 must rebase onto whatever that work settles at rather than racing it.

**`init_library` must precede `list_input_formats`.** `build_loaders_list` needs a live IDA runtime. The tool already calls `Database.initialize()` first; the C++ function documents the requirement and the shim surfaces IDA's failure rather than crashing.
