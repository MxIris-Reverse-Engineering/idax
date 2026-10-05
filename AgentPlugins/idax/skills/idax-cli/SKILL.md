---
name: idax-cli
description: >-
  Building IDA Pro databases (.i64) headlessly with the idax CLI — `idax binary` for
  executables, dylibs and .app / .framework bundles (it loads the host's slice of a universal
  Mach-O where unattended IDA takes x86_64), several at once with --output-dir and --jobs,
  `idax dyld-cache` for images inside a dyld shared cache (--image-name, --load-got), and
  `idax formats` for diagnosis. Read before running idax, and whenever a task needs an IDA
  database that does not exist yet. Triggers on idax, "create an IDA database", "build an .i64".
---

# idax

`idax` creates IDA databases without the IDA GUI, through idalib. Reach for it whenever a task
needs a `.i64` and none exists — do not stall, and do not ask a person to export one by hand.

It only **creates** databases. Reading one — decompiling, disassembling, cross-references — is
the job of an IDA MCP server's tools (for example the `idalib` server of the `ida-pro-mcp`
plugin: `decompile`, `disasm`, `xrefs_to`) or of IDAPython.

## 0. Before the first run

`idax` needs macOS 13 or later and IDA Professional 9.4 with idalib: its dyld shared cache work
goes through the public cache service IDA introduced in 9.4. Nothing bundles IDA or a license.

```bash
command -v idax || echo 'idax is not installed'
idax --help                      # the subcommands
idax help binary                 # every option of one subcommand; generated from the code
```

It is installed from a checkout of the `feat/swift-bindings` branch of
[MxIris-Reverse-Engineering/idax](https://github.com/MxIris-Reverse-Engineering/idax):
double-click `bindings/swift/Install idax.command` in Finder (it finds `cmake` and the IDA
runtime itself), or run `bindings/swift/scripts/install_idax_command_line.sh` with `IDADIR`
set to IDA's `Contents/MacOS` directory. The launcher lands in `~/.local/bin`.

Two signs that the installed build is older than this skill — reinstall from the branch when
either shows up:

- `idax binary` given a bundle answers `The binary does not exist` — the build predates bundle
  input.
- A run prints no `Working database directory:` line — the build predates the private working
  directory (§7), so two runs against one input are **not** safe and a crash leaves residue
  beside the input.

## 1. Pick the subcommand

| Input | Command |
|---|---|
| An app's executable, a dylib, a plug-in, any thin or universal Mach-O, an ELF, a PE | `idax binary <path>` |
| A bundle — `.app`, `.framework`, `.appex`, `.xpc`, an iOS-style flat bundle | `idax binary <bundle>` — its executable is loaded |
| An Apple system framework or library | `idax dyld-cache` — since macOS 11 their binaries exist only in the dyld shared cache |
| "Which slices does this file have, and which would be loaded?" | `idax formats <path>` — creates nothing |

**Never hand a universal binary to IDA unattended to build a database** — see §2. `idax binary`
exists to prevent exactly that.

## 2. `idax binary` and the architecture trap

A universal ("fat") Mach-O holds several architecture slices. IDA running unattended loads the
**first**, and `lipo` orders slices by CPU type, which puts x86_64 ahead of arm64 in everything
Apple's toolchain builds. So an arm64 application silently gets analysed as x86_64 — the
disassembly is x86, the decompilation is wrong, and nothing announces it.

`idax binary` selects the slice matching the host instead, preferring `arm64` over `arm64e`
when a file offers both (`--arch arm64e` reverses that preference).

```bash
idax binary /path/to/UniversalApp
idax binary --arch x86_64 /path/to/UniversalApp
idax binary /path/to/App --output /path/to/databases/App.i64 --overwrite
```

- `--arch` accepts `arm64`, `arm64e`, `x86_64`. Omit it to follow the host.
- **Read the proof in the output.** `Selecting arm64 (slice 2 of 3)` is the choice; `Loaded as:`
  is the format IDA itself reports after opening. If IDA loaded a different architecture than
  was selected, the run fails and nothing is saved.
- A universal file that offers neither the requested nor the host architecture is an error
  listing what it does contain — never a silent substitution. Pass `--arch` to pick one of the
  listed slices.
- A thin Mach-O, an ELF or a PE is opened with IDA's own detection (`Loading with IDA's
  detected format`). `--arch` on such a file is an error, not a silent no-op.
- `could not confirm the loaded architecture` → run `idax formats <path>`: it prints the slices,
  the loaders IDA offers for them and the slice `idax binary` would select.

**Naming.** Without `--output` or `--output-dir` the database is named after the input file
minus its extension, in the current directory (`libfoo.dylib` → `libfoo.i64`). `--output`
names one file; a missing extension is completed with `.i64`.

## 3. Bundles

A bundle path works wherever a binary path does. Its executable is found the way
`Bundle.executableURL` finds it, so there is no need to spell out `Contents/MacOS/Foo` or
`Versions/A/Foo`.

```bash
idax binary /Applications/Foo.app
idax binary /Applications/Foo.app/Contents/Frameworks/Bar.framework
```

- The resolution is printed first: `Loading the executable of <bundle>: <executable>`.
- The database is named after the **executable**, not the bundle. Usually the same name; an app
  whose executable is called `Electron` gives `Electron.i64`. Use `--output` to choose.
- A bundle and the path of its own executable are the same input: giving both is rejected,
  because they would produce the same database.
- **An on-disk Apple system framework is an error, by design** — `AppKit.framework` names an
  executable it does not contain. The message says so and points at `idax dyld-cache`.
- A directory that is not a bundle is an error.
- Nested bundles are not expanded: only the main executable is loaded. Give an app's
  `Frameworks/*.framework` or `PlugIns/*.appex` separately — a glob is fine.

## 4. Several binaries at once

```bash
idax binary AppA AppB AppC --output-dir /path/to/databases
idax binary /Applications/Foo.app/Contents/Frameworks/*.framework \
  --output-dir /path/to/databases --jobs 4
```

- `--output-dir` (which must exist) receives one database per input, each named after it.
  `--output` names a single file and is rejected with several inputs; the two cannot be
  combined. `--arch`, `--overwrite` and `--skip-final-analysis` apply to every input.
- **Everything knowable up front is checked before any analysis starts**: a missing input, a
  missing output directory, an existing output without `--overwrite`, and two inputs deriving
  the same database name. That last one is the common one — every app bundle names its
  executable after the bundle, so two `Contents/MacOS/App` paths both derive `App.i64`. Rename
  or split the run; it never renames for you.
- **Glob the bundles, not their insides.** `*.framework/Versions/A/*` also matches `Resources`
  and `_CodeSignature` — directories that are not bundles — and the whole batch is rejected
  before it starts.
- Each input is built in a child process of its own: the architecture slice is fixed once per
  process when IDA initialises. So a malformed input that kills IDA costs one database, not the
  batch, and a failure does not stop the others.
- `--jobs` defaults to 1, which keeps output live. Above 1, each input's output is held back
  and printed whole when it finishes.
- The run ends with a summary — `==> 3 binaries: 2 succeeded, 1 failed` — listing each failure
  with its exit status and a `rerun:` command that reproduces it alone. Read the summary rather
  than counting `Created database:` lines.

## 5. `idax dyld-cache` — frameworks in a shared cache

```bash
idax dyld-cache \
  --cache /path/to/dyld_shared_cache_arm64e \
  --image-name AppKit UIKitCore UIKitMacHelper \
  --load-got
```

- `--cache` takes the main cache file — no `.01`, `.atlas`, `.map` or other suffix. The parts
  beside it are found by name.
- `--image-name` **accepts several names, space separated**. A name matches an image path's
  last component with its extension removed (`libobjc.A` matches `/usr/lib/libobjc.A.dylib`),
  and the first match in cache order wins. To be exact, use `--image-path` with the complete
  in-cache path; the two can be combined (names resolve first, then paths). An unmatched name,
  a missing path, or two selectors landing on one image is an error.
- **Put frameworks that call each other into one database.** Each is its own image; in a
  single-image database every cross-framework jump goes nowhere.
- **Always pass `--load-got`** (short for `--load-global-offset-tables`). Without the global
  offset table regions, cross-image calls and data references do not resolve.
- Optional regions: `--load-branch-islands`, `--load-branch-mappings`,
  `--load-unknown-regions` (IDA 9.3 called them gaps; `--load-gaps` is accepted),
  `--load-cache-data` (cache-wide named data such as the linkedit sub-cache mappings), and
  `--load-dyld-header`, which IDA 9.4 already loads — the flag is harmless.
- Without `--output`, the database is named after the selected images joined with `+`, in the
  current directory: the example writes `AppKit+UIKitCore+UIKitMacHelper.i64`.
- It is a long job — minutes to an hour, and a database of hundreds of MB to several GB. Run it
  in the background with the output going to a log file.
- **Do not judge which images loaded from the log alone.** The first selected image is the base
  that IDA's loader opens; it never prints a `Loading image:` line — only the others do. When
  the run finishes, open the database and look up one known symbol per requested image (an IDA
  MCP server's `lookup_funcs`, say).

## 6. Reading the result honestly

- **Never judge success through a pipe.** `idax … | tail` reports the exit status of `tail`, and
  buffering can bury a `FATAL ERROR` mid-output. Redirect stdout and stderr together to a file,
  then read the file and the exit status separately.
- **Success is exit status 0 and a last line `Created database: <path>`.** Without that line
  the database was not written, whatever else was printed.
- Exit status `64`: idax refused the request — a bad or conflicting argument, a missing input,
  an existing output without `--overwrite`, an image name with no match, an architecture it
  could not confirm. The message on stderr says which.
- Exit status `1`: IDA itself failed to open, analyse or save; or, in a batch, at least one
  input failed (see the summary).
- A `FATAL ERROR: Oops! internal error NNNNN occurred.` line means IDA aborted. Treat the run as
  failed whatever the exit status, and do not trust any `.i64` it left.
- `--overwrite` replaces the old database only after loading and analysis have succeeded — a
  failed run leaves the previous database intact.
- `--skip-final-analysis` saves without draining IDA's auto-analysis queue: faster, but the
  database is not fully analysed yet.

## 7. Where IDA's working database goes, and what leftovers mean

IDA unpacks its working database — `.id0`, `.id1`, `.nam`, `.til` — beside the file it opens,
and `.i64` is the packed form of exactly those. Only a clean close packs them back and deletes
them. And IDA finds an unpacked database **by input file name**: a stray
`dyld_shared_cache_arm64e.id0` next to a cache makes IDA refuse to open that cache directly from
then on (`open_database failed`, or an internal-error abort) — in the GUI, in `idat`, in an MCP
server. Two runs opening one input at the same time spoil each other the same way.

`idax` therefore never hands IDA the input path, which also makes it immune to such leftovers.
Each run creates a private directory
(`Working database directory: …/idax-work-<pid>-<id>`), hard-links the input into it under the
same name — with a cache's other parts, but never with IDA database files lying beside it —
opens the link, and deletes the directory when it finishes. Consequences:

- **Concurrent runs are safe**, including several against one shared cache.
- **Inputs under `/bin`, `/usr` and `/System` are copied**, with a line saying so: the sealed
  system volume refuses hard links.
- **A hard link cannot cross volumes**, so the private directory goes in the temporary
  directory when that is on the input's volume, and beside the input otherwise — normal for a
  cache on an external disk. `--work-dir` chooses it explicitly and must be on the input's
  volume.
- A symbolic link given as input is replaced by the file it names first.
- **A run that is killed or aborts leaves its `idax-work-…` directory behind.** Nothing cleans
  those up; delete one once no run is using it.

**Leftovers beside an input therefore came from something else** — the IDA GUI, `idat`, a
killed IDA or MCP session, or an `idax` predating the private directory. Delete them (after
making sure no IDA session still has that database open), rather than trying to use or repair
them. And never `kill -9` an IDA session — including an MCP server holding a database — when a
graceful stop is possible: that is how residue gets made.

## 8. When idax is the wrong tool

- **Analysing an existing `.i64`** → an IDA MCP server's tools, not `idax`.
- **Scripting inside a database** (renaming, retyping, batch edits) → IDAPython, through the
  MCP server or the `idapython` skill of the `ida-pro-mcp` plugin.
- **You need a GUI session** → `idax` is headless by design; it only creates databases.

## 9. Where the details live

`idax help <subcommand>` is generated from the code and cannot drift. The full guide is
[`docs/Tools/IDAXCommandLine.md`](https://github.com/MxIris-Reverse-Engineering/idax/blob/feat/swift-bindings/docs/Tools/IDAXCommandLine.md)
on the `feat/swift-bindings` branch.
