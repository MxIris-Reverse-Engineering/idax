#!/usr/bin/env python3
"""Find damage a merge leaves behind that still compiles and still tests green.

Three failure modes, all observed during the August 2026 upstream sync:

1.  Leftover conflict markers, in files nothing builds (docs, YAML, ledgers).

2.  Duplicated content. Union merge keeps both sides of every hunk, which is
    correct for append-only ledgers and wrong for tables: README ended up with
    seven domain rows present twice, one current and one months stale. The
    superset heuristic used for code hunks mis-fired the same way, duplicating
    three type definitions in a header and a whole block of Rust methods.

3.  Resurrected host paths. Upstream rewrote its history to scrub personal
    paths; union merge restored several of them by keeping our older copies of
    documents upstream had already cleaned.

None of this fails a build, so it has to be looked for on purpose.

Usage:
    scripts/check_merge_residue.py [paths...]      # defaults to the repo root

Exit status is 1 when anything is found.
"""

from __future__ import annotations

import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

CONFLICT_MARKER = re.compile(r"^(<<<<<<<|=======|>>>>>>>|\|\|\|\|\|\|\|)")

# Host paths that must never be committed. See rule 9 in agents.md: use
# semantic tokens (<repo-root>, <ida-sdk-root>, <ida-runtime>) instead.
HOST_PATH = re.compile(r"/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+|/Volumes/[A-Za-z0-9._-]+")
HOST_PATH_ALLOWED = re.compile(r"/Users/<|/home/<|/Volumes/<|<userhome>|<upstream-source>")

# A table row's identity is its first cell; a list entry's is its first symbol.
TABLE_ROW = re.compile(r"^\|\s*([^|]{2,60}?)\s*\|")

# Union keeps both sides of one hunk, so its duplicates sit within a few
# lines of each other — the August 2026 README damage was 1-3 lines apart.
# Anything further apart is almost always legitimate repetition, such as a
# checksum quoted in several sections of a validation report.
NEARBY_LINES = 8

# Duplicated prose is only detectable by reading; duplicated code is not.
PROSE_SUFFIXES = {".md"}   # not .txt — CMakeLists.txt is code

SKIP_DIRECTORIES = {".git", "node_modules", "target", ".build", "_deps"}
TEXT_SUFFIXES = {".md", ".txt", ".yml", ".yaml", ".toml", ".json", ".cmake",
                 ".hpp", ".cpp", ".h", ".c", ".rs", ".swift", ".js", ".ts",
                 ".py", ".sh"}


def tracked_files(roots: list[str]) -> list[Path]:
    listing = subprocess.run(["git", "ls-files", "-z", *roots],
                             capture_output=True, text=True, check=True)
    paths = []
    for name in listing.stdout.split("\0"):
        if not name:
            continue
        path = Path(name)
        if SKIP_DIRECTORIES & set(path.parts):
            continue
        if path.suffix.lower() in TEXT_SUFFIXES:
            paths.append(path)
    return paths


def read_lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8", errors="replace").split("\n")
    except OSError:
        return []


def is_boilerplate(line: str) -> bool:
    """Lines that legitimately repeat: separators, closing braces, examples."""
    stripped = line.strip()
    if len(stripped) < 45:
        return True
    if set(stripped) <= set("-=|_* \t#"):
        return True
    # Repeated code inside fenced examples is normal in design documents.
    return stripped.startswith(("```", "//", "#", "*", ">"))


def check(path: Path) -> list[str]:
    lines = read_lines(path)
    problems: list[str] = []

    for number, line in enumerate(lines, 1):
        if CONFLICT_MARKER.match(line):
            problems.append(f"{path}:{number}: conflict marker left in place")
            break

    for number, line in enumerate(lines, 1):
        if HOST_PATH.search(line) and not HOST_PATH_ALLOWED.search(line):
            problems.append(
                f"{path}:{number}: host path — use a semantic token instead "
                f"({HOST_PATH.search(line).group(0)})")
            break

    # Everything below looks for duplicated *prose*. Duplicated code is the
    # compiler's job — it reports redefinitions far more precisely than a line
    # comparison can, and legitimately repeated lines (test setup, repeated
    # assertions) would drown the signal here.
    if path.suffix.lower() not in PROSE_SUFFIXES:
        return problems

    # Same table row identity appearing more than once, in the same table.
    rows: dict[str, list[int]] = defaultdict(list)
    for number, line in enumerate(lines, 1):
        match = TABLE_ROW.match(line)
        if match and not set(match.group(1)) <= set("-: "):
            rows[match.group(1)].append(number)
    for key, numbers in rows.items():
        if len(numbers) > 1:
            problems.append(
                f"{path}:{numbers[0]}: table row '{key[:40]}' repeats at "
                f"line(s) {', '.join(str(n) for n in numbers[1:])}")

    # Identical substantial lines repeating *close together*. Union merge keeps
    # both sides of one hunk, so what it duplicates ends up adjacent. Repeats
    # scattered across a long document are usually legitimate — recurring
    # hashes in a validation report, a command echoed in several sections.
    positions: dict[str, list[int]] = defaultdict(list)
    for number, line in enumerate(lines, 1):
        if not is_boilerplate(line):
            positions[line.strip()].append(number)
    for line, numbers in positions.items():
        nearby = [(a, b) for a, b in zip(numbers, numbers[1:])
                  if b - a <= NEARBY_LINES]
        if nearby:
            first, second = nearby[0]
            problems.append(
                f"{path}:{first}: line repeated at {second} "
                f"({second - first} lines apart) — {line[:70]}")

    return problems


def merge_touched_files() -> list[Path]:
    """Files this merge actually changed, plus anything still uncommitted.

    Scanning the whole repository is the wrong default: long-lived documents
    legitimately repeat themselves (a checksum quoted in several sections, a
    function signature shown once per overload in a design note), and none of
    that is merge residue. What matters is what this merge introduced.
    """
    names: set[str] = set()
    for command in (["git", "diff", "--name-only", "HEAD^1", "HEAD"],
                    ["git", "diff", "--name-only", "HEAD"],
                    ["git", "diff", "--name-only", "--cached"]):
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode == 0:
            names.update(result.stdout.split())
    return [Path(n) for n in sorted(names)
            if Path(n).suffix.lower() in TEXT_SUFFIXES and Path(n).exists()]


def main(argv: list[str]) -> int:
    if argv[1:]:
        paths = tracked_files(argv[1:])
        scope = " ".join(argv[1:])
    else:
        paths = merge_touched_files()
        scope = "files touched by this merge"
        if not paths:
            print("Nothing changed by this merge; pass paths to scan explicitly.")
            return 0

    findings: list[str] = []
    for path in paths:
        findings.extend(check(path))
    print(f"Scanned {len(paths)} file(s): {scope}\n" if findings else "", end="")

    if not findings:
        print("No merge residue found.")
        return 0

    for finding in findings:
        print(finding)
    print(f"\n{len(findings)} issue(s). Duplicated prose and stale table rows "
          f"survive builds and tests — they only go away if someone looks.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
