<!-- Fork-local records. See .agents/fork/README.md. -->

# Findings (fork)

Entries this fork added to `.agents/findings.md`, moved here so that file can track
upstream byte for byte. Numbering is whatever it was before the move; it is
independent of upstream's, which is exactly why these live in a separate file
— upstream's Phase 23 is an ida-trida port, ours was the Swift dyld cache
tool, and both had claimed `P23.1`.

---

365. **`ida::instruction::Operand` already exposes processor-marked semantic read/write at the C++ level, but the Swift binding silently dropped it:** `InstructionAccess::populate` in `src/instruction.cpp` reads `raw.get_canon_feature(*processor)` and sets `operand.read_ = has_cf_use(feature, i)` / `operand.written_ = has_cf_chg(feature, i)` per operand index, and `Operand::is_read()` / `is_written()` are part of the public API. The Swift shim's `IdaxOperand` struct simply omitted these two fields, so downstream Swift consumers (including LIR adapter authors) saw the C++ accessors as inaccessible. Re-checking C++ implementation *before* designing a new API path can avoid duplicate work — the fix here was a 2-field shim extension plus a Swift converter line, not a new C++ feature.
366. **Mnemonic-based branch-condition classification is more portable than processor-specific itype decoding for IDA-wrapper libraries:** A cross-architecture `BranchCondition` enum can be populated from the rendered mnemonic alone (ARM64 `B.<cc>`, ARM32 `B<cc>`, x86 `J<cc>`, plus exact matches for `CB[N]Z` / `TB[N]Z` / `JCXZ` / `LOOP*`). This sidesteps SDK processor-private headers (e.g. ARM64 `cond` field in `insn_t.auxpref`) and remains stable across processor module updates because IDA's print_insn_mnem output is the authoritative human-facing form. Wrappers that adopt `parse_branch_condition_from_mnemonic` keep their opaque boundary intact — no processor-module includes required.
367. **Handle-only C ABIs lose enrichment data that `ExpressionView`/`StatementView` carry by shared-pointer, so parent-chain queries need a visitor-scoped thread-local sidecar:** `ida::decompiler::ExpressionView`/`StatementView` internally hold a `std::shared_ptr<const std::vector<CtreeItemView>> parents_` that the SDK populates when `VisitOptions::track_parents = true`. The Swift/Node/Rust shims represent handles as bare `const void* raw_handle()` pointers, so reconstructing the view from `(void*)handle` in an accessor like `idax_ctree_expr_parent(handle, *out)` does not see the `parents_` chain. The robust solution that preserves the existing single-pointer ABI is to maintain a per-visitor `unordered_map<const void*, CtreeItemView>` keyed by `raw_handle()`, populated inside each visitor callback before invoking the user callback, and exposed via a `thread_local` pointer with RAII save/restore for re-entrant visits. Accessors look up the map; outside a visitor the lookup returns `has_value = 0`, which matches the existing "valid only during visitor callback" handle contract.
368. **Hand-mirrored C ABI headers across language bindings drift silently:** The shim header existed as two copies (`bindings/rust/idax-sys/shim/idax_shim.h` and `bindings/swift/Sources/CIDAX/include/idax_shim.h`) maintained by parallel edits. By the time it surfaced as a problem, neither copy was a strict superset of the other — Rust carried `IdaxPluginActionContext.type_ref_*`, lvar-snapshot/session handles, path/function/type accessors; Swift carried `idax_sync_ida_globals` and SE-0447 `__counted_by`/`__noescape` annotations. A reviewer scanning either file alone could not detect drift on the other side. The fix is structural: one file at a neutral path (`bindings/c/include/idax_shim.h`) referenced by every binding's build system, with at most a one-line thin re-export where SPM-style packaging requires the public header to live inside a target's source directory.
369. **Apple Clang 21+ `__counted_by` is a real attribute that participates in function-type identity, so SE-0447 annotations must appear on both declaration and definition:** When the shim's header declared `int idax_data_write_bytes(uint64_t ea, const uint8_t* __counted_by(len) data __noescape, size_t len)` but the implementation defined `int idax_data_write_bytes(uint64_t ea, const uint8_t* data, size_t len)`, Apple Clang 21 reported "conflicting types for ..." rather than silently ignoring the attribute. The fallback macro in `<ptrcheck.h>` only applies when `bounds_safety_attributes` is unavailable; on Apple Clang it is available and the attribute is real. Repeating the attributes on every annotated function definition makes declaration and definition agree on Apple Clang while remaining valid (no-op macro) on every other toolchain. Without this, Swift `Span<T>`-shaped overload synthesis can only stay on if the binding accepts shim build breakage, which it shouldn't.
370. **SPM `publicHeadersPath` is strictly under the target's `path` and cannot point at a sibling directory:** Even when the canonical header source lives outside any Swift target (e.g. a shared `bindings/c/include/` location used by every language binding), the Swift target still needs at least one `.h` under its own `path/publicHeadersPath` for SPM module-map generation. The minimum-friction pattern is a one-line thin re-export under the Swift target's `include/` that `#include`s the central header via an explicit relative path; the XCFramework packaging script populates the consumer-facing `Headers/` directly from the central file, so end consumers never depend on the re-export.
371. **复用的 ida-sdk FetchContent checkout 可能因未跟踪生成文件阻止 revision 切换而在编译前失败：** 已配置的 CMake build directory 可能重新执行 ida-sdk 更新并尝试 detach 或 rebase checkout。若其中存在 `src/cmake/idasdkConfig.cmake` 等未跟踪生成文件，Git 会拒绝切换 revision。应保留可能被共享的 checkout 状态，改用独立 build directory，并将 `IDASDK` 指向已有 SDK source tree，从而绕过 FetchContent 更新路径。
372. **`save_database` 可能失败，并且能够直接选择新的输出路径：** 该 IDA SDK 函数返回 `bool`，并接受可选输出文件名。此前 `ida::database::save()` 丢弃返回值，导致写入失败与成功无法区分。wrapper 对当前路径保存和显式路径保存都应检查结果，并在 IDA 报告失败时返回 SDK error。
373. **raw cache database 能枚举模块之前必须先选定第一个 dyld cache image（限制已由 F375 的 cache-path overload 消除）：** IDA Mach-O loader 在打开 raw cache 时读取 `IDA_DYLD_CACHE_MODULE`。原有 IDAX `DyldCache.listModules()` 读取当前数据库的 input path，因此首次打开前无法解析 basename；F375 新增的显式 cache-path 枚举让 name-only selector 可以在 open 前完成解析。
374. **Node 依赖安装脚本会在自定义 native build 环境准备完成前触发编译：** `npm ci` 会运行 package 的 `install` lifecycle，而该 lifecycle 会立即执行 `cmake-js`。验证需要自定义 `IDADIR`、`IDASDK` 或 `IDAX_BUILD_DIR` 时，应先运行 `npm ci --ignore-scripts`，再在环境完整后显式运行 `npm run rebuild`，避免依赖安装阶段以错误路径提前失败。
375. **按 image name 选择首个 dyld cache image 需要独立于 database lifecycle 的 cache-file 枚举：** `IDA_DYLD_CACHE_MODULE` 必须在 `Database.open` 前获得完整 image path，而原有无参数 `list_modules()` 依赖当前 database input path。将现有 header parser 抽成 `list_modules(cache_path)` overload，才能先按 path 最后一个 component 去除 extension 后匹配 name，再设置环境变量并打开 database。
376. **dyld shared cache 中同一个 derived image name 可能对应多个 path：** macOS 26.5.2 cache 的 `SwiftUI` 同时匹配 macOS framework、iOSSupport framework 和 Accessibility bundle。name selector 若直接把多重匹配视为错误，会让常见的 `--image-name SwiftUI` 不可用。稳定行为是保留 cache enumeration order 并选择第一条；需要其他同名 path 时由 `--image-path` 显式消歧。
377. **SwiftPM executable 使用 binary framework target 时不能只复制 executable：** consumer build 产出的 `idax-dyld-cache-database-creator` 通过 `@rpath/CIDAX.framework/CIDAX` 链接，并包含 `@loader_path` rpath。只把 executable 放入 `~/.local/bin` 会丢失 framework runtime dependency。稳定的当前用户安装布局是把 executable 与 `CIDAX.framework` 放在同一个 `libexec` directory，再由 `PATH` 中的 launcher `exec` 真实 executable；这样不需要修改 Mach-O install name、追加 rpath 或重新签名。
378. **IDA 9.4 将 DSC programmatic surface 从 private numeric plugin modes 迁移到 public `dscu_svc_t`：** `dscu.h` 提供 image index/name/address query、`region_info_t`、`dscu_load_request_t`、atomic `load_regions` 与 loaded-state verification。9.4 adaptation 应直接使用该 service，不能继续假设 9.3 reverse-engineered mode numbers 与 netnode tags 在新版保持 contract。
379. **IDA 9.4 SDK CMake entry point 已改变：** 9.3 checkout 通过 root `bootstrap.cmake` 引入 build helpers，而 9.4 checkout 提供 `src/cmake/idasdkConfig.cmake`，不再包含 root bootstrap。IDAX configure 必须先识别 config package layout，并只在存在时 include legacy bootstrap。
380. **Dynamic framework 中 exported IDA data stub 会破坏 IDA 9.4 plugin loading：** `CIDAX.framework` 原先导出的 null `callui` / `dbg` / `under_debugger` 会被 dynamic loader 用来 interpose `_ida_dscu.so` 对 libida globals 的引用，导致 `init_library` 从空 call gateway 跳到 address zero。将这些 stub 标记 hidden 后仍可满足 framework 内部链接，同时 9.4 runtime plugin 会绑定真实 libida symbols，初始化和 DSC open 均恢复正常。
381. **IDA 9.4 新增 `rt_cache_data`，且真实 macOS 26.5.2 cache 会返回多个 region：** public load request 为 cache-wide named data 提供独立 `cache_data` vector 与 `is_cache_data_loaded` verification。真实 AppKit database smoke test 加载 6 个 cache-data regions 并成功保存，因此该类型应作为明确 API/CLI option 暴露，而不是归入 unknown regions。

- **F4. Rebase-replayed history makes every date-based lookup wrong.**
  `git rebase --onto` preserves author dates and rewrites committer dates, so
  all 87 commits replayed on 2026-08-04 carry author dates spanning 2026-02-12
  → 2026-07-17 against a single committer date. `git log` / `rev-list` filter
  `--since` / `--before` by committer date, so a date-bounded lookup skips the
  entire replayed history and lands on upstream's line. Cross-checking the
  commit date does not help for upstream commits that were never replayed:
  their dates are untouched, yet their content only reached this branch through
  the merge. Anchor topologically instead — `<merge>^1` for fork-side state,
  `<merge>^2` for upstream-side. A downstream consumer misdiagnosed a crash for
  an afternoon on this. Recorded in `docs/UpstreamSyncPlaybook.md` with the
  worked example.

- **F5. A unified diff hunk cannot tell you where a struct member sits.**
  `7a8 > int branch_condition;` was read as an insertion at field position 8
  shifting everything after it; it is in fact the last member of
  `IdaxInstruction` and shifts nothing. Appending and inserting produce
  identical-looking hunks. The real ABI break was two `int32_t` inserted into
  `IdaxOperand` between `byte_width` and `register_name`, moving `register_name`
  8 bytes later and turning it into a wild pointer for consumers holding a
  pre-merge archive. For any ABI question, print both structs in full and
  compare member order rather than reading the hunk.

- **F6. The C shim is one translation unit, so every consumer links every domain.**
  `libidax_shim.a` contains a single `idax_shim.o` referencing 47 `ida::script::*`
  symbols, so static linking pulls in `script.cpp.o` and its `_eval_expr`
  dependency whether or not the consumer touches any script API. This surfaced
  as `dyld: symbol not found in flat namespace '_eval_expr'` in a headless Swift
  consumer that had been linking with `-undefined dynamic_lookup` — which only
  ever worked because the archive happened to reference nothing needing eager
  binding. Upstream's shim has the same structure (also 47), so this is not
  fork-introduced. Fixed at the link line rather than structurally: Package.swift
  now resolves the IDA runtime and links `libida`/`libidalib` with an rpath.
  Splitting the shim per domain remains the real fix.

- **F7. DYLD_INSERT_LIBRARIES resolves the symbol and breaks initialisation.**
  Preloading `libida.dylib` makes `_eval_expr` bind, but idalib never runs its
  own initialisation, so the first call into `ida::database::init` dereferences
  null. Bind at link time with an rpath; never paper over a missing symbol by
  injecting the library at load time.

- **F8. Two microcode decoders exist, and only one changed.**
  `ida::decompiler` parses microcode through `parse_sdk_opcode` /
  `parse_sdk_instruction`; `ida::microcode::snapshot` has its own decoder that
  casts `insn.opcode` straight to an int (`src/microcode.cpp:312`) and never
  calls either. The 2026-08-04 merge flipped the decompiler decoder's fallback
  from `Error::unsupported` to `MicrocodeOpcode::Other` and added explicit
  mappings for `m_call` / `m_icall` / `m_goto` / `m_ijmp` / `m_ret`, so
  instructions that previously failed to decode now succeed — a behavioural
  break that is simultaneously ABI-compatible, since both enums appended their
  new values. Consumers of `ida::microcode::snapshot` observe none of it.
  The APIs that do reach the changed parser: `generate_microcode`,
  `MicrocodeContext::instruction_at_index`,
  `MicrocodeContext::last_emitted_instruction`, and nested-operand parsing.
  `decompile` is ctree-only and reaches none of it.

- **F9. Sizing a change by diffstat answers the wrong question.**
  A consumer was told to discard a measurement baseline on the strength of
  +578/+299 lines in the files they consume plus a real behavioural break in
  those files. Their re-run came back byte-identical because their calls never
  reached the changed function. Establishing that took one grep for the caller.
  Before telling anyone their baseline is void, trace from their entry point to
  the change; "this file changed a lot" and "this consumer is affected" are
  independent facts.

- **F10. Text-pattern function location is unreliable in this codebase.**
  Locating the function enclosing `src/decompiler.cpp:5412` with an awk pattern
  for column-zero signatures ending in a brace returned `decompile()`. The line
  belongs to `generate_microcode()`, whose return type sits on its own line. The
  wrong answer named the one function not affected by the change under
  investigation. Track brace depth or read the whole construct; this pairs with
  F5 — tools that approximate structure return confident wrong answers.
