# Swift Parity Completion Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the 313-function gap between the C ABI and the Swift bindings, move the module onto explicit Swift 6 actor isolation, and restore the consumer-mode XCFramework that has been broken since the August 2026 upstream merge.

**Architecture:** Three layers, two of which are already complete. `bindings/c/include/idax_shim.h` exposes 1066 functions and covers every C++ domain; the Rust bindings already wrap all of them. Only `bindings/swift/Sources/IDAX/` lags, and the packaged `CIDAX.xcframework` lags with it. Work happens in the Swift wrapper and in `Package.swift`; the C ABI is not touched.

**Tech Stack:** Swift 6.3 toolchain, swift-tools-version 6.2, macOS 13 deployment target, swift-testing, SPM.

---

## Background: the measured gap

Symbol-level diff of declarations in `bindings/c/include/idax_shim.h` against references in `bindings/swift/Sources/IDAX/*.swift`:

- C ABI declares **1066** unique functions.
- Swift references **745**.
- **321** are unreferenced; 8 of those are `*_free` helpers that Swift must not expose (it manages lifetime through `deinit`, and exposing them hands callers a double-free). **313 real gaps.**

Twelve domains sit at zero coverage. Eleven of them arrived with the merge; `path` is this fork's own.

| Domain | Functions | What it does |
|---|---|---|
| `script` | 44 | IDC evaluation, compilation, execution; IDC value object read/write/slice/attribute |
| `directory` | 25 | IDA's netnode directory tree — folder grouping, ordering, moves |
| `registry` | 22 | IDA registry read/write for configuration persistence |
| `navigation` | 20 | Jump history: back/forward/push/seek, multi-channel |
| `offset` | 17 | Offset references: apply, compute base, render expression |
| `registers` | 10 | Register value tracking: constant-at, stack delta, caches |
| `parser` | 9 | Third-party source parser selection and type ingestion |
| `bookmark` | 7 | Bookmark slots |
| `exception` | 6 | C++ EH and SEH handler region metadata |
| `problem` | 6 | IDA problem list |
| `undo` | 5 | Undo/redo points and action labels |
| `path` | 3 | basename / dirname / is_directory |

Seven more domains have Swift files but partial coverage: `data` 40/77 (the entire custom data format and type system), `type` 26/88 (kind, name, declaration, UDT/enum/function/pointer details, `parse_declarations`), `ui` 16/76 (wait box, clipboard, typed forms, `ask_text`, `current_widget`), `segment` 16/36 (the whole segment register range API), `event` 9/20, `decompiler` 15/72 (`generate_microcode`, `ScopedSession`, popup and pseudocode-switch subscriptions, user lvar settings), plus 15 scattered across `lines`, `instruction`, `function`, `database`, `name`, `processor`, `plugin`.

Several of the `ui` and `database` gaps are this fork's own codedump-parity work that Node and Rust both wrapped and Swift never did.

**The XCFramework is a separate, harder failure.** `bindings/swift/Frameworks/CIDAX.xcframework` was last built at `80b6e63`, the commit immediately before the merge. Its header carries 785 symbols and `nm` finds none of `_idax_script_evaluate`, `_idax_registry_open`, `_idax_type_name`, `_idax_segment_registers` in the binary. Consumer mode (`swift build`, `binaryTarget`) therefore cannot reach 281 functions even by dropping to raw `CIDAX` calls. Developer mode (`IDAX_DEV=1`) is unaffected: `bindings/swift/Sources/CIDAX/include/idax_shim.h` is a one-line `#include` forwarder to the central header.

**Reference implementations exist.** Rust already wraps every one of these domains — roughly 4300 lines across `bindings/rust/idax/src/{script,directory,registry,navigation,offset,registers,parser,bookmark,problem,exception,undo,path}.rs`. API shape, error semantics and handle lifetime are settled questions; the Swift work is translation, not design.

---

## Locked decisions

Each was chosen against a specific alternative. The alternatives are in the next section — they are the more valuable half of this document.

**Concurrency.** Declare `public typealias IDAActor = MainActor`, and set `.defaultIsolation(MainActor.self)` on the `IDAX` and test targets. One manifest line isolates all 1058 functions with no possibility of missing one, while `@IDAActor` remains available for expressing intent at declaration sites and in documentation. All 23 `@unchecked Sendable` annotations come off — they were asserting something the type system can now check. (The module mentions `Sendable` 117 times in total; the other 93 are ordinary conformances that stay.)

The executor must land on the main thread. This is a hard idalib requirement, not a style preference; see the rejected alternatives.

**Callbacks.** C trampolines stay `nonisolated`. Inside, `MainActor.assumeIsolated` recovers the isolation that is already factually in effect, then calls the user's isolated closure. Synchronous semantics are preserved because several IDA events use the handler's return value to decide what happens next.

**Language mode and strictness.** `swift-tools-version: 6.2` already defaults to Swift 6 language mode — verified: every one of the 14 `-swift-version` flags on the build command line reads 6, and none reads 5. Add `.swiftLanguageMode(.v6)` explicitly anyway, so a future tools-version bump cannot silently drift the mode.

Strict concurrency checking needs no setting. Xcode's `SWIFT_STRICT_CONCURRENCY` spec is conditioned on `EFFECTIVE_SWIFT_VERSION == 4 / 4.2 / 5` and its own description states it "is always 'complete' when in the Swift 6 language mode and produces errors instead of warnings."

Xcode's `SWIFT_APPROACHABLE_CONCURRENCY` has no single SPM equivalent. Its spec description enumerates five upcoming features; under Swift 6 the toolchain reports `DisableOutwardActorInference`, `GlobalActorIsolatedTypesUsability` and `InferSendableFromCaptures` as already enabled, leaving two to opt into. Enable those two plus two more:

- `NonisolatedNonsendingByDefault` (SE-0461) — runs `nonisolated` async functions on the caller's executor instead of hopping to the global pool. Directly load-bearing here: a hop off the main thread is a deadlock or a crash, not a performance question.
- `InferIsolatedConformances`
- `ImmutableWeakCaptures`
- `MemberImportVisibility` — near-zero cost, the module already uses `internal import CIDAX` in 29 places.

**Ownership.** Unchanged from the existing pattern: handles needing explicit release are `~Copyable` with `deinit` and a `consuming` explicit-release method, inputs are `borrowing`, value snapshots stay plain `struct`. New `~Copyable` handles: IDC values (`script`), registry keys, directory snapshots, navigation history.

**Naming.** Three domains are renamed where a literal translation misleads: `exception` → `ExceptionRegion` (it is handler-region metadata, not error handling, and `Exception` in Swift will be misread every time), `registers` → `RegisterTracking` (it tracks register values, it is not a register list), `path` → `FilePath`. Everything else takes the C++ domain name in UpperCamelCase. The `IDAX` module imports no Foundation, so there is no collision to design around.

**Testing.** swift-testing integration tests against the real fixture database, run by default. When `IDADIR` or the fixture is missing they must skip **visibly**, not silently pass — the existing `DyldCacheIntegrationTests` returns early and reports success, which is how a green suite can mean nothing was verified.

Measured, with enough tests to force parallel scheduling: `@MainActor` tests ran on the process main thread 24/24; `nonisolated` tests ran off it 24/24. So Swift needs no equivalent of the custom `harness = false` runner Rust was forced into.

**Distribution.** VERSION goes to 0.2.0. A new `docs/migration/swift-concurrency-adoption.md` explains why main-thread isolation is mandatory, what downstream must change, and how plugin and headless hosts differ. README gains a Swift bindings section. CI gains a macOS job in `bindings-ci.yml`, reusing its existing IDADIR resolution step — Swift is currently in no workflow at all, so nothing today catches even a compile break.

---

## Rejected alternatives

**Custom `SerialExecutor` on a dedicated background thread.** The obvious clean design, and it deadlocks. `bindings/rust/idax/tests/integration.rs` states the constraint: "The idalib runtime requires all calls on the thread that initialized it." Finding 373 in `.agents/findings.md` records what happens otherwise — IDAPython initialization emits a synchronous warning that enters IDA's main-thread execution path and waits on a semaphore, while libtest's main thread waits on the worker. `--test-threads=1` does not help; it controls concurrency, not thread identity. Rust ended up writing a custom sequential main-thread runner.

**A genuinely independent `@IDAActor` together with module-level default isolation.** Impossible as specified. `SwiftSetting.defaultIsolation` is declared `(_ isolation: _Concurrency.MainActor.Type?, ...)` — the parameter type is hardcoded, so no custom global actor can be passed. The typealias recovers the naming benefit at the cost of the semantics being genuinely `MainActor` underneath. If IDA ever relaxes its threading requirement, the alias is one line to change, but it will not be a drop-in swap.

**Plain `@MainActor` with no alias.** Honest, but it tells headless command-line users their code is UI-bound, and it erases the distinction in documentation and diagnostics.

**`~Escapable` with `@_lifetime` for zero-copy borrowed views** over IDC value slices and directory children. Requires enabling the `LifetimeDependence` experimental feature, and the attribute is still spelled with a leading underscore — not finalised. Revisit when it stabilises.

**Raising the deployment target.** Measured at macOS 13: typed throws, `~Copyable` with `consuming`/`borrowing`, `Span`/`MutableSpan`, actors, `async`/`await`, global actors and `AsyncStream` all compile. Only `InlineArray` requires macOS 26. Cutting off every pre-26 consumer to gain `InlineArray` is not a trade worth making, and IDA Pro itself does not require macOS 26.

**`AsyncStream` for event subscriptions.** Asynchronous delivery cannot carry a return value back to IDA, and by the time an event is consumed the database may have moved on. Some IDA events use the handler's return value.

**Folding strict memory safety into this work.** `.strictMemorySafety()` (SE-0458) is worth doing and is scheduled as Task 7, but not mixed into the other batches. The existing module has ~490 explicit unsafe type occurrences (`Unsafe*Pointer` 334, `Unmanaged<` 132, `withUnsafe*` 20) and the check is broader than that — even `String(cString:)` trips it. The resulting diff is a thousand-plus lines of pure `unsafe` annotation; reviewable on its own, unreviewable if interleaved with 313 new functions.

Note that `SwiftSetting.strictMemorySafety()` takes no mode argument, so the `MIGRATE` tier is only reachable through `unsafeFlags`, which would make the package unusable as a dependency. Task 7 therefore applies migration as a temporary, uncommitted manifest edit.

**`ExistentialAny`.** 63 bare existentials would need rewriting. Unrelated to concurrency; keep this diff on one subject.

**`.treatAllWarnings(as: .error)` from the start.** Enable only after all batches land and the warning count has been observed stable at zero. Turning it on early means an Xcode point release or an upstream merge can red the build over code that is not ours.

---

## Task 1: Foundation batch — bookmark, problem, undo, navigation, FilePath

41 functions. Deliberately the smallest domains, because this task also establishes the patterns every later task copies. Getting the model wrong costs 41 functions of rework, not 313.

Establish, in this order:

1. `Package.swift`: `.swiftLanguageMode(.v6)`, `.defaultIsolation(MainActor.self)` on `IDAX` and both test targets, and the four `.enableUpcomingFeature` entries.
2. `bindings/swift/Sources/IDAX/Concurrency.swift`: `public typealias IDAActor = MainActor`, plus documentation of why isolation is mandatory.
3. Remove `@unchecked Sendable` module-wide; fix whatever the compiler then reports. This will touch existing files and is expected to be the noisy part of this task.
4. Convert the `Event.swift` trampolines to the `nonisolated` + `assumeIsolated` pattern as the reference implementation for later callback work.
5. Add the five domains, each mirroring its Rust counterpart.
6. Integration tests against the fixture, with a visible-skip helper that later tasks reuse.

**Acceptance:** `IDAX_DEV=1 swift build` and `swift test` both clean; the new integration tests actually execute against the fixture (verify by asserting a non-zero assertion count, not by a green result); no `@unchecked Sendable` remains.

## Task 2: Handle-shaped domains — registry, directory, RegisterTracking

57 functions. First real exercise of the `~Copyable` handle pattern: registry keys and directory snapshots both open, nest and must close. `directory` also carries ordering and rank semantics worth reading out of `directory.rs` rather than inferring from the C header.

## Task 3: offset, parser, ExceptionRegion

32 functions. `offset` includes expression rendering, which returns owned strings — check the free-function pairing carefully. `parser` selects third-party source parsers and its language enumeration includes Swift. `ExceptionRegion` returns nested region metadata with optional stack displacement and frame register.

## Task 4: script

44 functions, the hardest single domain. IDC values are reference-counted objects with clone, deep-copy, slice, attribute enumeration and dereference. This is where the `~Copyable` model gets its real test, and where `script.rs` (945 lines) is most worth following closely rather than reinventing.

## Task 5: data and type completion

66 functions. `data` is the custom data format and type system — registration, attachment to standard types, rendering, scanning — plus string literal list configuration. `type` adds kind and name queries, structured UDT/enum/function/pointer details, forward-declaration handling and `parse_declarations`. Both extend existing files rather than creating new ones.

## Task 6: ui, segment, event, decompiler completion and stragglers

73 functions. `ui` gains wait boxes, clipboard, the five fixed typed-form entry points, `ask_text` and `current_widget`. `segment` gains the whole register-range API. `event` gains nine subscriptions. `decompiler` gains `generate_microcode`, the scoped Hex-Rays session (`initialize` plus a move-only `ScopedSession`), popup and pseudocode-switch subscriptions, user lvar settings capture/restore, and variable comments. Stragglers: `lines` source files, `instruction` operand enums, `function` prototype application, `database.idbPath` and processor profile, `name.all` and `name.demangle`.

## Task 7: strict memory safety

Whole-module `unsafe` annotation via SE-0458.

1. Temporarily add `.unsafeFlags(["-strict-memory-safety:migrate"])` to the `IDAX` target — **do not commit this state**.
2. Build and apply the emitted fix-its. The migrate tier emits machine-applicable replacements; they are visible with `-diagnostic-style=llvm` (`= unsafe p`, `unsafe `) but not in the default style.
3. Replace the temporary flag with `.strictMemorySafety()`.
4. Review the diff. It should contain nothing but `unsafe` markers; anything else means the migration changed behaviour and must be investigated.

**Acceptance:** clean build with `.strictMemorySafety()` and no `unsafeFlags` in the committed manifest.

---

## Per-task closing protocol

Every task ends with all of:

1. `IDAX_DEV=1 swift build` and `swift test` clean.
2. `bindings/swift/scripts/build-xcframework.sh` rerun, the rebuilt XCFramework committed, and consumer-mode `swift build` verified against it. Both modes must work at every commit; leaving consumer mode broken between batches reproduces exactly the failure this plan exists to fix.
3. Fork records updated under `.agents/fork/` with `F`-prefixed numbering — roadmap status, progress ledger entry, and findings plus knowledge base when something was learned. Never the upstream ledgers.
4. One commit containing code, tests, XCFramework and records together.

---

## Verification

Beyond per-task acceptance, before declaring the plan complete:

- Re-run the symbol diff that produced the 313 figure and confirm it reports only the 8 intentionally-excluded `*_free` helpers.
- `nm` the rebuilt XCFramework binary for a sample from each newly added domain.
- Build from a clean clone with no prior state, following the README. Local worktrees hide anything `.gitignore` is eating — that is how the Swift package was unbuildable from a clean clone for months without anyone noticing.
- Confirm the downstream `swift-decompiler` adapter builds against the new isolation model, since it is the one known consumer.

## Risks

**The isolation change is breaking for every existing caller.** That is inherent to the decision, not a side effect to be mitigated; the migration guide and version bump exist to make it legible.

**Task 1 carries most of the model risk.** If `assumeIsolated` in the trampolines turns out to be wrong for some callback that IDA invokes off the main thread, the pattern must change before Task 2 copies it six more times. Any callback whose thread of invocation is not established should be treated as unknown and verified against a live database rather than assumed.

**The fixture may not exercise every domain.** `tests/fixtures/simple_appcall_linux64` is a small ELF64; it will not have meaningful dyld cache, debugger or Lumina state. Where a domain cannot be exercised against it, say so in the test and in the ledger rather than writing an assertion that passes vacuously.
