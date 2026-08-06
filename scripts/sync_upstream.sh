#!/usr/bin/env bash
# sync_upstream.sh — merge 19h/idax into this fork with the checks that the
# August 2026 sync proved were necessary.
#
# What that sync taught, and what this therefore automates:
#
#   - A merge can delete public API without conflicting. Upstream had removed
#     an overload; auto-merge accepted it silently and only the Swift bindings
#     noticed, at compile time. Every run now diffs the API surface.
#
#   - bindings.rs is generated. Merging it textually produces duplicate extern
#     blocks that compile. It is regenerated from the merged header instead.
#
#   - Union merge is right for ledgers and wrong for prose. Both behaviours are
#     declared in .gitattributes; the residue checker catches what slips past.
#
#   - Green tests prove nothing about documentation. Duplicated table rows and
#     resurrected host paths survive every build.
#
# Usage:
#   scripts/sync_upstream.sh [--remote NAME] [--branch NAME] [--no-verify]
#
# Stops at the first conflict for manual resolution, then re-run to continue.

set -euo pipefail

REMOTE="upstream"
BRANCH="master"
RUN_VERIFY=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --remote) REMOTE="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --no-verify) RUN_VERIFY=0; shift ;;
        -h|--help) sed -n '2,/^set /{ /^#/!d; s/^# \{0,1\}//; p; }' "$0"; exit 0 ;;
        *) echo "error: unknown option: $1" >&2; exit 1 ;;
    esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*"; }

# ── Preconditions ────────────────────────────────────────────────────────
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree is dirty; commit or stash first" >&2
    exit 1
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
    echo "error: no remote named '$REMOTE'" >&2
    exit 1
fi

# merge=ours in .gitattributes needs a driver; git ships no built-in one.
git config merge.ours.driver true

BEFORE="$(git rev-parse HEAD)"
say "Fetching $REMOTE/$BRANCH"
git fetch "$REMOTE" "$BRANCH"

if ! git merge-base --is-ancestor "$(git rev-parse "$REMOTE/$BRANCH")" HEAD 2>/dev/null; then
    :
fi

if [[ -z "$(git merge-base HEAD "$REMOTE/$BRANCH" 2>/dev/null || true)" ]]; then
    cat >&2 <<'EOF'
error: no common ancestor with upstream.

This is the situation the August 2026 sync had to resolve once, by rebasing
this fork's post-divergence commits onto the matching upstream commit. It is
not something to automate blindly — see docs/UpstreamSyncPlaybook.md, section
"When there is no common ancestor".
EOF
    exit 1
fi

BEHIND="$(git rev-list --count "HEAD..$REMOTE/$BRANCH")"
if [[ "$BEHIND" == "0" ]]; then
    say "Already up to date with $REMOTE/$BRANCH"
    exit 0
fi
say "$BEHIND upstream commit(s) to merge"

# ── Merge ────────────────────────────────────────────────────────────────
say "Merging"
if ! git merge --no-edit "$REMOTE/$BRANCH"; then
    CONFLICTS="$(git diff --name-only --diff-filter=U)"
    warn "$(printf '%s\n' "$CONFLICTS" | wc -l | tr -d ' ') file(s) conflict"
    printf '\n%s\n' "$CONFLICTS"
    cat <<EOF

Resolve, 'git add' them, 'git commit', then re-run this script to finish the
checks. Guidance per category is in docs/UpstreamSyncPlaybook.md.

Two rules worth repeating here:
  - Prefer upstream for shared code unless this fork's version is a superset
    or fixes something. Record why in .agents/fork/decision_log.md.
  - Never resolve a documentation conflict by keeping both sides blindly;
    that is what left seven duplicated README rows last time.
EOF
    exit 1
fi

# ── Regenerate what is generated ─────────────────────────────────────────
say "Regenerating bindings.rs from the merged C ABI header"
if command -v cargo >/dev/null 2>&1 && [[ -n "${IDASDK:-}" ]]; then
    (
        cd bindings/rust
        CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-target}" cargo build -p idax-sys >/dev/null
        GENERATED="$(find "${CARGO_TARGET_DIR:-target}" -name bindings.rs -path '*out*' | head -1)"
        if [[ -n "$GENERATED" ]]; then
            cp "$GENERATED" idax-sys/src/bindings.rs
            echo "   regenerated from $GENERATED"
        else
            warn "bindgen produced no bindings.rs; check the build log"
        fi
    )
else
    warn "skipped: needs cargo and IDASDK. Run it before trusting bindings.rs."
fi

# ── Checks that a green build does not cover ─────────────────────────────
say "Checking for public API lost to the merge"
python3 scripts/check_api_surface_loss.py "$BEFORE" || {
    warn "API disappeared in the merge. Every line above is either an"
    warn "intentional upstream removal or an accident — decide explicitly."
    warn "Nothing else here will catch it: the C++ library still compiles,"
    warn "because the callers that break live in the bindings."
}

say "Checking for merge residue in prose"
python3 scripts/check_merge_residue.py || true

# ── Verification ─────────────────────────────────────────────────────────
if [[ "$RUN_VERIFY" == "0" ]]; then
    say "Skipping verification (--no-verify)"
else
    say "Verifying"
    cat <<'EOF'
Run these; all four layers matter, and the integration suites matter most —
they are what proves upstream's own domains still behave after a merge:

  cmake -B build -DIDAX_BUILD_TESTS=ON && cmake --build build -j
  ctest --test-dir build --output-on-failure            # needs IDADIR
  (cd bindings/rust && cargo test -p idax --lib)
  (cd bindings/node && npm test)
  bindings/swift/scripts/build-libs.sh && swift test

And once, from a clean clone, to catch anything .gitignore is eating:
  git clone -b <branch> <this fork> /tmp/clone-check && cd /tmp/clone-check
EOF
fi

say "Merge complete: $(git rev-parse --short "$BEFORE") -> $(git rev-parse --short HEAD)"
echo "Record the outcome in .agents/fork/progress_ledger.md (F-prefixed entry)."
