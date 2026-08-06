#!/usr/bin/env python3
"""Report public declarations that exist on one ref but not on another.

Written after an upstream sync silently dropped an overload: upstream had
deleted `set_operand_struct_offset(Address, int, uint64_t, AddressDelta)`,
auto-merge accepted the deletion without conflict, and nothing surfaced it
until the Swift bindings failed to compile — they were still calling it.

A merge that deletes API is not necessarily wrong; upstream removes things on
purpose. What is wrong is deleting API *silently*. Run this after any sync and
decide deliberately about every line it prints.

Usage:
    scripts/check_api_surface_loss.py <before-ref> [<after-ref>]

    before-ref  the state whose API must not vanish, e.g. HEAD@{1} or the
                pre-merge commit
    after-ref   defaults to the working tree

Exit status is 1 when anything was lost, so it can gate a sync script.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# A declaration ending in ';' at namespace scope, plus enum/struct/class heads.
DECLARATION = re.compile(
    r"^[A-Za-z_][\w:<>,\s\*&\[\]]*?\b\w+\s*\([^;{]*\)\s*(?:const\s*)?(?:noexcept\s*)?;",
    re.MULTILINE,
)
TYPE_HEAD = re.compile(r"^\s*(?:enum class|struct|class)\s+(\w+)", re.MULTILINE)


def normalize(text: str) -> str:
    """Collapse whitespace so reformatting is not reported as a change."""
    return re.sub(r"\s+", " ", text).strip()


def list_headers(ref: str | None) -> list[str]:
    if ref is None:
        return sorted(str(p) for p in Path("include/ida").glob("*.hpp"))
    listing = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", ref, "include/ida/"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    return sorted(p for p in listing if p.endswith(".hpp"))


def read(ref: str | None, path: str) -> str:
    if ref is None:
        try:
            return Path(path).read_text(encoding="utf-8", errors="replace")
        except FileNotFoundError:
            return ""
    result = subprocess.run(["git", "show", f"{ref}:{path}"],
                            capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else ""


def surface(ref: str | None) -> dict[str, set[str]]:
    """Map each header to the set of declarations and type names it exposes."""
    out: dict[str, set[str]] = {}
    for path in list_headers(ref):
        text = read(ref, path)
        if not text:
            continue
        entries = {normalize(m.group(0)) for m in DECLARATION.finditer(text)}
        entries |= {f"type {m.group(1)}" for m in TYPE_HEAD.finditer(text)}
        out[path] = entries
    return out


def main(argv: list[str]) -> int:
    if not 2 <= len(argv) <= 3:
        print(__doc__, file=sys.stderr)
        return 2

    before_ref = argv[1]
    after_ref = argv[2] if len(argv) == 3 else None
    after_label = after_ref or "working tree"

    before = surface(before_ref)
    after = surface(after_ref)

    lost_total = 0
    for path, entries in sorted(before.items()):
        lost = entries - after.get(path, set())
        if not lost:
            continue
        lost_total += len(lost)
        print(f"\n{path}  ({len(lost)} lost)")
        for entry in sorted(lost):
            print(f"    - {entry[:160]}")

    dropped_headers = sorted(set(before) - set(after))
    for path in dropped_headers:
        print(f"\n{path}  (header removed entirely)")

    print()
    if lost_total or dropped_headers:
        print(f"{lost_total} declaration(s) present in {before_ref} are absent "
              f"from {after_label}.")
        print("Each one is either an intentional upstream removal or an "
              "accident. Decide explicitly — do not merge past this.")
        return 1

    print(f"No public declarations lost between {before_ref} and {after_label}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
