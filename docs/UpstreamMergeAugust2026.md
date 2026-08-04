# Upstream Merge, August 2026

Record of the merge that brought this fork back in line with `19h/idax`, and of
the pull request that followed from it.

## Motivation

This fork had been developing independently since March 2026 while upstream
kept moving: by August it had advanced roughly four months and about 250
substantive commits, adding eleven domains (`bookmark`, `directory`,
`exception`, `navigation`, `offset`, `parser`, `problem`, `registers`,
`registry`, `script`, `undo`) and a complete Python binding. Staying behind
meant every future rebase would only get more expensive, and any pull request
offered upstream would conflict on contact.

## The obstacle: no common ancestor

`git merge upstream/master` refused outright — the two histories share no
commit. Upstream had rewritten its entire history to scrub personal paths
(`/Users/int/...` → `<userhome>`), so identical work carried different SHAs on
each side, down to and including the initial commit.

The trees, however, had not diverged. At 2026-02-28 the two sides differed by
ten files and fifty lines, all of them that same path scrubbing. That made the
histories re-alignable rather than merely mergeable:

1. `git rebase --onto <upstream 2026-02-28> <our 2026-02-28>` replayed this
   fork's 87 post-February commits onto the matching upstream commit. Only the
   binary test fixture conflicted.
2. `git merge upstream/master` then ran as an ordinary three-way merge.

The two branches now share ancestry, so **every future sync is a plain
`git merge`** and none of this applies again.

## Scope

The merge touched 491 files. 62 conflicted, across 305 hunks:

| Category | Handling |
|---|---|
| Documentation and agent ledgers | Union merge, then de-duplicated (see below) |
| Superset relationships (one side contained the other) | Resolved automatically after verifying subsequence containment |
| C ABI shim | Rebuilt at function granularity — see below |
| Core library, bindings, tests | Resolved individually |

`bindings/swift/`, `include/ida/dyld_cache.hpp` and `include/ida/microcode.hpp`
merged without conflict; neither side had touched the other's files.

## Key decisions

### The C shim was rebuilt, not merged

`idax_shim.cpp` was the hardest file, and resolving it hunk-by-hunk would have
been wrong. The two sides had added disjoint function sets — 124 ours, 297
upstream, zero overlap — but diff had aligned unrelated functions against each
other, so every "conflict" was a false choice between two functions that both
needed to survive. Worse, the hunk boundaries fell inside function bodies, so
keeping both sides verbatim would not even have parsed.

It was instead reconstructed from the parsed function inventory: upstream's
file as the base, seventeen commonly-owned functions replaced with this fork's
versions, `fill_instruction` merged by hand (both sides had edited it), and the
124 fork-only functions appended.

That reconstruction initially dropped ten helpers and types, because the
extraction pattern only matched `idax_`/`fill_`/`free_`/`make_`/`to_`/`from_`
prefixes and these were named otherwise (`CtreeParentMap`, its scope guard,
`populate_ctree_parent_info`, `as_mutable_microcode_context`,
`ProcessorBridge`, the microcode snapshot accessors). They were found by
compiling, and a subsequent full-inventory comparison confirmed nothing else
was missing.

### What was taken from each side

Upstream's version was taken for:

- **`ask_text` format-string handling.** This fork appended the prompt to the
  format string and passed it as a `%s` argument, which silently disabled the
  `ACCEPT TABS` / `NORMAL FONT` directives — IDA only honours those at the
  start of the format string itself.
- **`catch_unwind` around Rust FFI action handlers**, preventing a panic from
  unwinding across the FFI boundary.
- **Clipboard external-command fallback** (`pbcopy`, `xclip`, `wl-copy`,
  `clip.exe`) and the `clipboard_backend_name()` indirection.
- **The plugin action registry** — attachment counting, hotkey sequencing,
  process-lifetime adapter storage.
- **The sequential Rust integration-test harness** (`harness = false`). This
  fork had been marking tests `ignore` on Linux to work around segfaults; the
  root cause was calling into idalib off its initializing thread, which the new
  harness fixes properly.

This fork's version was kept for:

- **The `op_uses_x/y/z` guard in ctree operand navigation.** Upstream still
  dereferences `x`/`y` unguarded; for most opcodes those slots alias other
  members, so a deep ctree reads a non-pointer as a `cexpr_t*`.
- **`stack_offset` and `register_number` on `LocalVariable`.**

### One API was nearly lost

Upstream deleted the `set_operand_struct_offset(Address, int, std::uint64_t,
AddressDelta)` overload, keeping only the by-name form. Auto-merge accepted the
deletion silently — but `Instruction.swift` calls it. A sweep of every public
header confirmed this was the only such loss; it was restored, along with its
C ABI declaration.

### Documentation was union-merged, then cleaned

Union merge keeps both sides of every conflicting hunk, which is safe for
append-only ledgers but leaves visible damage where both sides edited the same
table row: two copies of the row, one current and one months stale. README
alone had seven duplicated domain rows.

It also resurrected content upstream had deliberately deleted — validation
runs and migration notes still carrying their author's personal paths. Since
upstream rewrote its history specifically to remove those, five documents were
reset to track upstream verbatim.

The remaining duplicates were resolved to upstream's version after checking,
word by word, that nothing this fork documented was lost. Three items upstream
genuinely did not cover were folded in: `database::save_to`, ctree
sub-structure navigation, and plugin invocation by name.

## Pre-existing defects surfaced along the way

None of these were introduced by the merge; all three predate it on this
fork's branch, and the first two were fixed as part of the upstream PR.

1. **`build*/` in `.gitignore` was unanchored.** It matched at any depth, and
   on a case-insensitive filesystem it also matched `BuildXCFramework/` — so
   the SPM command plugin's source could never be committed while
   `Package.swift` referenced it, meaning a clean clone could not build the
   Swift package. Fixed by anchoring to `/build*/`.
2. **`bindings/swift/.gitignore` was inert.** Its patterns were written as
   `bindings/swift/.build/`, but patterns in a nested `.gitignore` resolve
   relative to that file's own directory, so each expanded to
   `bindings/swift/bindings/swift/...`. The build directories were only ever
   ignored incidentally, by the root `*.a` and `*.o` rules.
3. **`tests/unit` could not configure.** This fork's umbrella header has listed
   42 includes since `microcode` and `dyld_cache` were added, against a parity
   expectation of 40, and no `check_microcode_surface` probe ever existed. The
   probe was written and the expectation moved to 42.

Additionally, `bindings/rust/idax-sys/build.rs` carried both
`use build_support::patch_bindgen_output` and a stale local definition of the
same function — an `E0255` hard error, meaning `idax-sys` had not compiled on
this branch either. The local copy also predated upstream's microcode struct.

## Impact

Nothing in this fork's public API changed except the restored overload. Two
Swift signatures changed, forced by upstream's C ABI:

- `Decompiler.setComment` / `.comment` take a `CommentPosition` value (kind
  plus argument-index or switch-case payload) instead of a raw `Int`. Both
  default to `.default`, so existing call sites keep working.
- `Instruction.operandStructOffsetPath` returns `(names:delta:)` rather than
  `(ids:delta:)`. Upstream stopped exposing raw SDK structure ids in favour of
  names; this is a breaking change with no alternative.

`Package.swift` gained IDA runtime discovery (`$IDADIR`, falling back to an
installed IDA under `/Applications`) and `-lc++`. Before this, `swift build`
and `swift test` could not link at all.

## Verification

Against IDA SDK 9.4 on macOS arm64, with a real IDA installation:

| Layer | Result |
|---|---|
| `ctest` | 42/42, including all 36 integration suites |
| `cargo test -p idax --lib` | 173 passed |
| `npm test` | 277 passed |
| `swift test` | 64 tests in 32 suites |
| Clean clone, following README | Builds and tests green |

The integration suites matter most here: they exercise the domains upstream
added over four months, so passing them is what establishes that the shim
reconstruction and the resolution choices did not break existing behaviour.

## Upstream pull request

[19h/idax#6](https://github.com/19h/idax/pull/6) offers the Swift bindings
upstream, opened as a draft at the maintainer's request in
[#5](https://github.com/19h/idax/issues/5). It carries the Swift package, the
two domains it depends on (`microcode`, `dyld_cache`), the C ABI header move to
`bindings/c/`, the core-library additions, and a `build-swift` CI job — 71
files across ten commits.

Deliberately excluded: the checked-in `CIDAX.xcframework` (3.2 MB), the
`swift-argument-parser`-based dyld cache CLI tool and its dependency, and
everything under `.agents/`, `docs/plans/` and `docs/superpowers/`.

Should upstream ask for the domains to be restructured or renamed, those
changes have to be mirrored back onto the merge branch before it is pushed —
which is why the merge branch is being held rather than published.
