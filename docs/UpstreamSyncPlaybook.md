# Upstream Sync Playbook

How to merge [`19h/idax`](https://github.com/19h/idax) into this fork without
repeating the August 2026 sync, which took a full day and left four defects
that a green build never showed.

`scripts/sync_upstream.sh` runs the mechanical parts. This document is for the
judgement the script deliberately refuses to make.

## The short version

```bash
scripts/sync_upstream.sh              # fetch, merge, regenerate, check
# resolve conflicts if it stops, commit, re-run
```

Then verify all four layers, and read what the two checkers printed. A merge
that compiles and passes tests can still have deleted public API and doubled
half your documentation.

## Sync often

The single biggest cost driver last time was waiting four months. Upstream had
moved ~250 commits and eleven domains; 62 files conflicted across 305 hunks.
Most of that would not have conflicted at all if the gap had been weeks.

Monthly is cheap. Quarterly is a project.

## Categories, and what to do with each

### Append-only ledgers — solved structurally

`.agents/*.md` and `agents.md` track upstream byte for byte. Fork records live
in `.agents/fork/` with `F`-prefixed numbering. Do not append to the upstream
ledgers; that is what made all seven conflict every time, and what let two
unrelated tasks share the number `P23.1`.

See `.agents/fork/README.md`.

### Generated artifacts — never merge

`bindings/rust/idax-sys/src/bindings.rs` is bindgen output, checked in only as
an offline fallback for docs.rs. `.gitattributes` marks it `merge=ours`; the
sync script regenerates it from the merged C ABI header afterwards. Merging it
textually yields duplicate `extern` blocks that compile fine and are wrong.

The same applies to any packaged framework binary.

### Prose and tables — resolve by hand, never union

This is counter-intuitive, so it is worth stating plainly: **union merge is
the wrong tool for documentation.** It keeps both sides of every hunk, which
means:

- Where both sides edited a table row, you get two rows — one current, one
  months stale. README ended up with seven such pairs.
- Where upstream *deleted* something, union puts it back. Upstream rewrote its
  entire history to scrub personal paths; union restored five documents'
  worth of them.

Resolve these by hand. When both sides edited the same row, take upstream's
and check word by word whether anything of ours is missing from it — upstream
often rewrites enumerated lists into wildcards (`revert_*` for a dozen named
functions), which reads as a loss and isn't one.

### Shared code — prefer upstream, with exceptions

Default to upstream's version. Keep ours only when it is a strict superset or
fixes something upstream still has wrong, and record why in
`.agents/fork/decision_log.md`.

From last time, for calibration:

| Taken from upstream | Because |
|---|---|
| `ask_text` format-string handling | Ours silently disabled the `ACCEPT TABS` directives |
| `catch_unwind` in Rust FFI handlers | Panics were unwinding across the FFI boundary |
| Clipboard external-command fallback | Strictly more capable |
| Sequential Rust test harness | Fixed the actual cause of Linux segfaults we had been suppressing with `ignore` |
| Plugin action registry | Strictly more capable |

| Kept ours | Because |
|---|---|
| `op_uses_x/y/z` ctree guard | Upstream still dereferences unguarded; those slots alias non-pointers |
| `stack_offset` / `register_number` on `LocalVariable` | Upstream has no equivalent |

### Large files where diff misaligns

`idax_shim.cpp` is the case to watch. Both sides add many functions; diff
aligns unrelated ones against each other and puts hunk boundaries inside
function bodies. Neither keeping nor discarding a side produces valid C++.

Do not resolve it hunk by hunk. Parse the file into functions, then merge at
that granularity:

1. Upstream's file is the base.
2. Replace functions where only this fork changed them.
3. Merge by hand the ones both sides changed.
4. Append the fork-only functions.
5. Compile — the compiler finds helpers the extraction missed. Last time it
   found ten, all named outside the `idax_`/`fill_`/`free_` patterns that the
   extraction matched.

## What a green build does not tell you

Four failure modes, all of which survived the initial verification last time:

**Deleted API.** Upstream removed an overload; auto-merge accepted it with no
conflict. The C++ library still compiled — the caller that broke was in the
Swift bindings. `scripts/check_api_surface_loss.py` compares the public
surface across the merge. Every line it prints is either an intentional
upstream removal or an accident; decide explicitly, one at a time.

**Duplicated definitions.** The superset heuristic used for code hunks
duplicated three type definitions in `decompiler.hpp` and a whole block of
methods in `decompiler.rs` — including one where a function body had been
spliced into another function. That one only surfaced through an "undeclared
identifier" error much later.

**Duplicated prose.** Nothing catches this but reading, or
`scripts/check_merge_residue.py`.

**Configuration that was already broken.** The merge surfaced three defects
that predated it: an unanchored `build*/` ignore rule eating
`BuildXCFramework/` on a case-insensitive filesystem, patterns in
`bindings/swift/.gitignore` written relative to the repository instead of
their own directory, and a 42-vs-40 umbrella-include mismatch that meant
`tests/unit` could not configure. Do not assume a failure after a merge was
caused by the merge — check the pre-merge branch.

## Verification

All four layers, with a real IDA installation:

```bash
cmake -B build -DIDAX_BUILD_TESTS=ON && cmake --build build -j
ctest --test-dir build --output-on-failure        # needs IDADIR
(cd bindings/rust && cargo test -p idax --lib)
(cd bindings/node && npm test)
bindings/swift/scripts/build-libs.sh && swift build && swift test
```

The integration suites carry the weight. Unit tests cover the error model and
range semantics; they pass whatever you do to the domain code. The 36
integration suites exercise upstream's own domains, so passing them is what
establishes that a merge did not regress upstream behaviour.

Then build from a clean clone, following the README with no prior state. Local
worktrees hide anything `.gitignore` is eating — that is how a clean clone was
unable to build the Swift package for months without anyone noticing.

## When there is no common ancestor

This happened once, in August 2026, because upstream rewrote its entire
history to scrub personal paths. Identical work carried different SHAs on both
sides, down to the initial commit, and `git merge` refused outright.

`--allow-unrelated-histories` is the wrong answer: it treats all 491 files as
conflicting.

What worked, and what to do if it recurs:

1. Find a date where the two trees were effectively identical. Compare
   `git diff <ours-at-date> <theirs-at-date>` across candidate dates; ours
   differed by ten files and fifty lines, all of it the path scrubbing.
2. Replay this fork's commits since that point onto upstream's commit from it:
   `git rebase --onto <upstream-at-date> <ours-at-date> <branch>`
3. Verify the replay changed nothing: diff the result against the original
   branch. Only the scrubbing should show.
4. `git merge upstream/master` now runs normally, and every future sync is an
   ordinary merge.

Do not automate this. It depends on the two trees genuinely having been
identical at the chosen point, which has to be checked rather than assumed.

## After a re-alignment, dates lie

The August 2026 re-alignment replayed 87 commits with `git rebase --onto`.
Rebase preserves each commit's **author** date and assigns a new **committer**
date, so on this branch:

- author dates still span 2026-02-12 → 2026-07-17
- committer dates are all 2026-08-04, for every one of the 87

`git log`, `rev-list` and friends filter `--since` / `--before` by **committer**
date. So a date-bounded lookup skips the entire replayed history and silently
lands on upstream's line instead:

```bash
# Wrong: excludes all 87 replayed commits (committed 08-04), lands upstream
git rev-list -1 --before="2026-07-16" HEAD

# Right: locate topologically
git show e9a8c3d^1:path/to/file    # our state just before the merge
git show e9a8c3d^2:path/to/file    # upstream's state at the merge
```

Anything that displays author dates — `%ad`, GitHub's commit list — compounds
it. `git log -S encoded_value_byte_offset` surfaces a commit dated 2026-07-14
for a field that actually arrived on 08-04, because `6da2c0e` was authored in
July and committed in August.

A downstream consumer lost an afternoon to exactly this. Their session, verbatim:

```bash
$ BASE=$(git rev-list -1 --before="2026-07-16 15:05" HEAD)
$ git log -1 --format='%h %s' $BASE
710ea139 Implement Phase 53 Diaphora exact referent metadata     # upstream's line, not ours
```

`710ea139` already carries post-merge content, so diffing `IdaxOperand` against
it showed nothing and they ruled out the struct that was actually crashing them.
The diff also reported the header as a whole-file addition — not because the
struct was new, but because the header used to live at a different path.

Cross-checking the commit date does not rescue you either:

```bash
$ git log --format='%h author=%ad commit=%cd %s' --date=short \
      -S encoded_value_byte_offset -- bindings/c/include/idax_shim.h \
                                      bindings/rust/idax-sys/shim/idax_shim.h
5bbc426 author=2026-07-14 commit=2026-07-14 feat: implement Phase 48 …
```

Both dates read July, which "proved" the fields predated their archive. That
commit was upstream's and was never replayed, so its dates are untouched — but
its *content* only reached this branch through the 08-04 merge. Dates describe
when a commit was written, never when it arrived here.

### A struct diff is not a layout diff

The same investigation misread this hunk:

```
7a8
>     int          branch_condition;
```

and concluded a field had been inserted at position 8, shifting everything after
it. `branch_condition` is the **last** member of `IdaxInstruction`; appending and
inserting produce identical-looking unified hunks. For an ABI question, print the
whole struct from both sides and compare member order — the hunk alone cannot
tell you where a field sits.

Two further traps in the same area:

- **The C ABI header moved.** It was `bindings/rust/idax-sys/shim/idax_shim.h`
  until the merge, now `bindings/c/include/idax_shim.h`. `git log -S … --
  <current path>` returns nothing for anything older; use `--follow`.
- **The merge commit itself is not a baseline.** `e9a8c3d` has two parents and
  carries content from both. For "what did we have before", use `e9a8c3d^1`
  (= `80b6e63`); for "what did upstream have", `e9a8c3d^2`.

## Publishing after a re-alignment

A rebase-based re-alignment rewrites history, so publishing needs a force-push.
Before any `--force` or `--force-with-lease`:

```bash
git fetch origin <branch>
git cherry HEAD @{u}        # lines starting with '+' exist only on the remote
```

`--force-with-lease` does **not** protect against this. Its lease only checks
that the remote tip is the one you last fetched; it will happily let a local
branch overwrite a remote that contains commits the local branch never had.
Integrate anything substantial before pushing.
