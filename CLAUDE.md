# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**idax** is a fully opaque, domain-driven C++23 wrapper over the IDA Pro SDK. It replaces the SDK's raw C-heritage API with a consistent, self-documenting interface using `std::expected<T, Error>` error handling, value semantics, and RAII patterns. Version 0.1.0, MIT licensed.

The project has four surfaces: the C++ static library (`libidax.a`), Rust bindings (`bindings/rust/`), Node.js bindings (`bindings/node/`), and Swift bindings (`bindings/swift/`).

**This fork tracks upstream and adds one thing: the `idax` command-line tool.**
Every upstream C++ file here is byte-identical to upstream. The fork's own code
lives only in paths upstream does not have — `include/ida/fork/`,
`src/fork_input_format.cpp`, `bindings/swift/Sources/CIDAXFork/`,
`bindings/swift/Tools/`, and `docs/fork/`. Before adding anything else, read
[the shrink proposal](docs/fork/evolutions/draft-shrink-fork-to-cli.md): keeping
that intrusion at zero is what makes upstream syncs cheap.

## Build Commands

### Environment Variables

- `IDASDK` — IDA SDK root (auto-fetched from `HexRaysSA/ida-sdk` if unset)
- `IDADIR` — IDA Pro install path (required for integration tests and runtime)

### C++ Library

```bash
# Configure
cmake -B build -DIDAX_BUILD_TESTS=ON -DIDAX_BUILD_EXAMPLES=ON

# Build
cmake --build build

# Run all tests (unit + integration; integration needs IDADIR)
ctest --test-dir build --output-on-failure

# Run only unit tests (no IDA runtime needed)
ctest --test-dir build --output-on-failure -R "idax_unit_test|api_surface_parity|error_torture|address_range_torture|diagnostics_torture|core_options_torture"

# Run a single test by name
ctest --test-dir build --output-on-failure -R <test_name>

# Validation matrix script (profiles: full, unit, compile-only)
scripts/run_validation_matrix.sh unit build-unit RelWithDebInfo
```

### Rust Bindings

```bash
cd bindings/rust

cargo build
cargo test --lib                                         # Unit tests only
cargo test --test integration -- --test-threads=1        # Integration (needs IDADIR)
cargo run --example <example_name>                       # Run an example
```

### Node.js Bindings

```bash
cd bindings/node

npm install --ignore-scripts
npx cmake-js compile
npm test                    # Unit tests
npm run test:integration    # Integration tests (needs IDADIR)
```

### Swift Bindings and the `idax` Command-Line Tool

The Swift bindings are upstream's. This fork adds only the `idax` tool
(`bindings/swift/Tools/`) and a separate C transport module for what upstream
does not have (`bindings/swift/Sources/CIDAXFork/`).

```bash
export IDADIR="/Applications/IDA Professional 9.4.app/Contents/MacOS"

# Build the native archive once (CMake). The package manifest finds it itself.
bindings/swift/scripts/build-libs.sh

swift build --product idax
swift test --filter IDAXCommandLineTests   # no IDA runtime needed

# Build and install the tool for the current user
./scripts/install_idax_command_line.sh
```

Without a prebuilt archive the manifest falls back to upstream's pkg-config
route, which needs `PKG_CONFIG_PATH` set to the CMake-generated metadata — see
`bindings/swift/README.md`.

## Architecture

### Opaque Boundary

`src/detail/sdk_bridge.hpp` is the **single point** where IDA SDK headers are included. Public headers under `include/ida/` never include any SDK file. Internal `friend struct XxxAccess` patterns allow `.cpp` files to populate opaque value objects.

### Library Structure

- **Static library** (`libidax.a`) with 28 `.cpp` compilation units, one per domain namespace
- **SDK-agnostic linkage**: consumers link `idax::idax` plus their own `idasdk::plugin`, `idasdk::idalib`, or `idasdk::loader`
- **Value semantics**: `Segment`, `Function`, `Instruction`, `Operand`, `TypeInfo` are value snapshots, not live SDK pointers
- **Pimpl for heavy types**: `TypeInfo` hides `tinfo_t` via `detail/type_impl.hpp`; `DecompiledFunction` holds a ref-counted `cfuncptr_t` and is move-only
- `database_lifecycle.cpp` is separated from `database.cpp` to isolate idalib-only symbols

### Domain Namespace Map

30 public headers in `include/ida/`, each mapping to a `src/*.cpp`:

`address`, `analysis`, `comment`, `core`, `data`, `database`, `debugger`, `decompiler`, `diagnostics`, `dyld_cache`, `entry`, `error`, `event`, `fixup`, `function`, `graph`, `instruction`, `lines`, `loader`, `lumina`, `name`, `plugin`, `processor`, `search`, `segment`, `storage`, `type`, `ui`, `xref`

Master include: `#include <ida/idax.hpp>`

### Error Model

All fallible operations return `ida::Result<T>` (`std::expected<T, ida::Error>`) or `ida::Status` (`std::expected<void, ida::Error>`). `Error` contains `category` (enum), `code`, `message`, and `context`.

### Bindings Architecture

- **Rust** (`bindings/rust/`): Cargo workspace with `idax-sys` (raw FFI via C shim + bindgen) and `idax` (safe idiomatic layer). The C shim (`idax-sys/shim/`) uses thread-local error state. `build.rs` invokes CMake to build `libidax.a`, then `cc` for the shim, then `bindgen`.
- **Node.js** (`bindings/node/`): Native addon via `cmake-js` + `nan`. 20 C++ bind files in `src/`, JS wrapper in `lib/index.js` with TypeScript declarations. Addresses are `BigInt`, errors throw `IdaxError`.
- **Swift** (`bindings/swift/`): upstream's SPM package (Package.swift at repo root). `CIDAX` is a system-library target over the canonical C transport; `IDAX` is the safe wrapper using Swift 6 typed throws (`throws(IDAError)`). Upstream builds the native archive `idax_swift_native` with CMake and consumes it through pkg-config. **Fork deviations in `Package.swift`**: a prebuilt-artifact route (the manifest links `libidax_swift_native.a` directly when it finds one, so `swift build` needs no pkg-config setup), the `idax` executable and its `CIDAXFork` C module, and no `IDAXShared` dynamic product — that is the support image for upstream's native add-ons, which this fork does not build, and a product cannot carry the linker settings the prebuilt route needs.

### Testing Layers

| Layer | Location | Runtime |
|---|---|---|
| Unit tests (error model, ranges, diagnostics) | `tests/unit/` | None |
| API surface parity (compile-only) | `tests/unit/api_surface_parity_test.cpp` | None |
| Integration tests (21 suites) | `tests/integration/` | idalib + fixture |
| Downstream integration (add_subdirectory/FetchContent) | `integration/` | SDK only |

Test fixture: `tests/fixtures/simple_appcall_linux64` (ELF64) with pre-analysed `.i64` database.

macOS integration tests link against real IDA dylibs from `/Applications/IDA Professional 9.4.app/Contents/MacOS` (not SDK stubs) due to two-level namespace constraints.

## Coding Conventions

- **Full words, always**: `address` not `ea`, `remove` not `del`, `comment` not `cmt`, `operand` not `op`
- **Verb-first naming**: `read_byte`, `write_byte`, `find_binary_pattern`
- **No SDK types in public API**: no `segment_t*`, `func_t*`, `insn_t`, no `.raw()` escape hatch
- **No flag bitmasks in public API**: use structured option types and typed enums
- **RAII for subscriptions**: `ScopedSubscription` guard pattern for event handlers
- C++23 standard, `-Wall -Wextra -Wpedantic` on GCC/Clang, `/W4 /permissive-` on MSVC

## Agent Knowledge Base

`.agents/` is the distributed source of truth for this project's roadmap, progress,
findings, and decisions. The upstream hub file is `agents.md` at the repo root; its
operating rules are reproduced below, with the write destinations adjusted for this
fork.

### Upstream ledgers vs. fork records

This repository is a fork of [`19h/idax`](https://github.com/19h/idax). `agents.md` and
every `.agents/*.md` one level up track upstream **byte for byte and must not be edited
here**. Appending to them is what made all seven ledgers conflict on every sync, and what
let two unrelated tasks share the number `P23.1` (upstream's was an ida-trida port, this
fork's was the Swift dyld cache tool).

**`.agents/fork/` was frozen on 2026-09-13.** Those seven mirrored ledgers belong to the
era when this fork carried a parallel Swift bindings implementation; after the shrink the
fork's increment is too small to justify them. Read them for history, do not append.

**New fork records go in `docs/fork/`**: evolution proposals in `docs/fork/evolutions/`,
and code-review findings ruled a false positive or not worth fixing in
`docs/fork/adjudicated-findings.md`. Upstream will never have that path, so it stays
conflict-free across syncs.

Touch an upstream ledger only when the change is genuinely upstream's: fixing its typo, or
preparing a pull request that has to follow its numbering. See `.agents/fork/README.md`
for the split and `docs/UpstreamSyncPlaybook.md` for the sync procedure that depends on it.

### File map

| File | Contents | When to read | Fork counterpart (frozen 2026-09-13 — read only) |
|---|---|---|---|
| `agents.md` (repo root) | Upstream's rules, mission, locked decisions | Rarely — this section supersedes it for fork work | none (read-only) |
| `.agents/knowledge_base.md` | Hierarchical findings/learnings KB (Section 12) | Checking known SDK behaviour | `.agents/fork/knowledge_base.md` |
| `.agents/findings.md` | Raw findings log, referenced as `[FXXX]` | Tracing a KB entry to its evidence | `.agents/fork/findings.md` |
| `.agents/decision_log.md` | Architectural decisions (Section 13) | Making a design decision | `.agents/fork/decision_log.md` |
| `.agents/progress_ledger.md` | Detailed progress history (Section 15) | Logging completed work | `.agents/fork/progress_ledger.md` |
| `.agents/active_work.md` | In-progress, queued, and blocked work only (Section 16) | Picking up work or checking status | `.agents/fork/active_work.md` |
| `.agents/roadmap.md` | Phased TODO roadmap + progress snapshot (Sections 10-11) | Checking phase status | `.agents/fork/roadmap.md` |
| `.agents/api_catalog.md` | Public API concept catalog (Section 17) | Implementing new APIs | `.agents/fork/api_catalog.md` |
| `.agents/architecture.md` | Analysis recap, target architecture, domain mapping, build/test/doc strategy (Sections 4-9) | Designing a new domain | none — architecture is stable |
| `.agents/interface_blueprint.md` | Detailed interface sketches (Section 21) | Implementing a specific namespace; the actual headers are authoritative | none |
| `.agents/pain_points.md` | Legacy SDK friction catalog (Section 18) | Designing wrapper behaviour | none |
| `.agents/naming_normalization.md` | Legacy-to-wrapper naming map (Section 19) | Naming new APIs | none |
| `bindings/node/agents.md` | Exhaustive Node.js binding API reference written for agents | Working on or calling the Node bindings | none (upstream-tracked) |

**Append-friendly convention.** Every file uses hierarchical numbered sections. To add an
entry, read only the **tail** (~50 lines) of the target file to learn the current
numbering, then append. Reading the whole file is unnecessary for most updates — several
of these run to hundreds of thousands of bytes.

### Mandatory update protocol

No task is complete until the records are updated. A change that is not recorded is
treated as work that did not happen.

**The seven-ledger protocol below applied until the ledgers were frozen on 2026-09-13.**
It is kept because `.agents/fork/` still has to be read as history. For new fork work:

1. Substantive changes headed for a shared branch get an evolution proposal in
   `docs/fork/evolutions/`, updated in place from research through landing. One change is
   one file — never split into separate design/plan/report documents.
2. Code-review findings ruled a false positive or not worth fixing go in
   `docs/fork/adjudicated-findings.md`, with the reasoning that makes the ruling checkable
   next time.
3. Everything else the repository already records — code structure, git history — is not
   duplicated into a ledger.

The frozen protocol, for reading `.agents/fork/`:

1. Update the task checkbox/status in `.agents/fork/roadmap.md` as soon as it changes.
2. Add a progress ledger entry with scope in `.agents/fork/progress_ledger.md`.
3. If a technical insight was discovered, add it to **both** `.agents/fork/findings.md` and
   `.agents/fork/knowledge_base.md`.
4. If architecture changed, record it with rationale in `.agents/fork/decision_log.md`.
5. If blocked, add or update `.agents/fork/active_work.md` with impact, mitigation, and the
   next action.
6. When work completes or is retired, remove it from `.agents/fork/active_work.md` in the
   same update that records the completion.

Two transitions are only half-valid without their pair: a TODO status change requires a
ledger entry, and a discovery requires both a knowledge base entry and a ledger entry.

**Never commit identity-bearing absolute host paths.** Use semantic tokens — `<repo-root>`,
`<ida-sdk-root>`, `<ida-runtime>`, `<upstream-source>` — in documentation and evidence, and
audit both tracked text and binary strings before pushing.

### Locked technical decisions

Explicitly chosen and currently locked; changing any of them requires a decision log entry:

1. **C++23** as the language standard.
2. **Hybrid packaging** — header-only for thin wrappers and utility aliases, compiled
   library for complex behaviour, stateful adapters, iterators, and lifecycle management.
3. **Fully opaque public API** — no `.raw()` escape hatches, no SDK structs or pointers in
   the public interface.
4. **`std::string`** as the public string type; `std::string_view` is allowed for input
   where it is safe.
5. **Full scope** — plugins, loaders, and processor modules.

Engineering preferences to honour during implementation:

- Prefer straightforward, portable implementations.
- Avoid compiler-specific intrinsics unless unavoidable.
- Avoid heavy bit-level micro-optimisation that reduces readability.
- Prefer SDK helpers (including `pro.h` helpers) where they improve portability or clarity.
- For batch analysis and testing workflows, prefer `idump <binary>` over `idat`.

## CI/CD

- `.github/workflows/validation-matrix.yml` — Main CI: Linux (GCC) + macOS (Apple Clang) + Windows (MSVC), profiles `compile-only` and `unit`
- `.github/workflows/bindings-ci.yml` — Rust + Node.js bindings on 3 platforms
- `.github/workflows/integration-ci.yml` — Downstream integration (add_subdirectory + FetchContent)
- `.github/workflows/node-plugin-release.yml` — Tagged release builds for Node prebuilds
