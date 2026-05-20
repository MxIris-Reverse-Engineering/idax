# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**idax** is a fully opaque, domain-driven C++23 wrapper over the IDA Pro SDK. It replaces the SDK's raw C-heritage API with a consistent, self-documenting interface using `std::expected<T, Error>` error handling, value semantics, and RAII patterns. Version 0.1.0, MIT licensed.

The project has four surfaces: the C++ static library (`libidax.a`), Rust bindings (`bindings/rust/`), Node.js bindings (`bindings/node/`), and Swift bindings (`bindings/swift/`).

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

### Swift Bindings

```bash
# Build XCFramework (arm64 + x86_64, requires IDASDK)
bindings/swift/scripts/build-xcframework.sh

# Build — consumer mode (uses XCFramework)
swift build

# Build — developer mode (uses pre-built .a files)
bindings/swift/scripts/build-libs.sh   # pre-build first
IDAX_DEV=1 swift build

# Test (unit only — no IDA runtime needed)
swift test
```

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
- **Swift** (`bindings/swift/`): SPM package (Package.swift at repo root) with two targets — `CIDAX` (raw C shim module) and `IDAX` (safe Swift wrapper). Uses Swift 6.0 typed throws (`throws(IDAError)`). 21 namespace files mirror the C++ library. Dual-mode: consumer mode uses `CIDAX.xcframework` (binaryTarget), developer mode (`IDAX_DEV=1`) links pre-built `.a` files. IDA dylibs loaded at runtime via dlopen.

### Testing Layers

| Layer | Location | Runtime |
|---|---|---|
| Unit tests (error model, ranges, diagnostics) | `tests/unit/` | None |
| API surface parity (compile-only) | `tests/unit/api_surface_parity_test.cpp` | None |
| Integration tests (21 suites) | `tests/integration/` | idalib + fixture |
| Downstream integration (add_subdirectory/FetchContent) | `integration/` | SDK only |

Test fixture: `tests/fixtures/simple_appcall_linux64` (ELF64) with pre-analysed `.i64` database.

macOS integration tests link against real IDA dylibs from `/Applications/IDA Professional 9.3.app/Contents/MacOS` (not SDK stubs) due to two-level namespace constraints.

## Coding Conventions

- **Full words, always**: `address` not `ea`, `remove` not `del`, `comment` not `cmt`, `operand` not `op`
- **Verb-first naming**: `read_byte`, `write_byte`, `find_binary_pattern`
- **No SDK types in public API**: no `segment_t*`, `func_t*`, `insn_t`, no `.raw()` escape hatch
- **No flag bitmasks in public API**: use structured option types and typed enums
- **RAII for subscriptions**: `ScopedSubscription` guard pattern for event handlers
- C++23 standard, `-Wall -Wextra -Wpedantic` on GCC/Clang, `/W4 /permissive-` on MSVC

## Agent Knowledge Base

The `.agents/` directory contains the distributed knowledge base for this project (architecture decisions, roadmap, findings, progress). The hub file is `agents.md` at the repo root. Consult `.agents/architecture.md` for design rationale, `.agents/roadmap.md` for phase status, and `.agents/decision_log.md` for past architectural decisions.

## CI/CD

- `.github/workflows/validation-matrix.yml` — Main CI: Linux (GCC) + macOS (Apple Clang) + Windows (MSVC), profiles `compile-only` and `unit`
- `.github/workflows/bindings-ci.yml` — Rust + Node.js bindings on 3 platforms
- `.github/workflows/integration-ci.yml` — Downstream integration (add_subdirectory + FetchContent)
- `.github/workflows/node-plugin-release.yml` — Tagged release builds for Node prebuilds
