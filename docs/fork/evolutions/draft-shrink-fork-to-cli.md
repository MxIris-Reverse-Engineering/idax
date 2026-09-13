# Draft - 收缩为上游之上的命令行工具

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-09-13
- **最后更新**: 2026-09-13
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / PR**: `feat/swift-bindings`（就地收缩，收缩前打归档标签）
- **配套文档**: 待定 —— 落地时登记

## 摘要

放弃在这个 fork 里维护一整套与上游平行的 Swift bindings，改为跟随上游 `19h/idax` 的
master 分支，只保留 `idax` 命令行工具和它必需的一小块 C++ 补丁。上游在 2026-09-08 关闭了
本 fork 的 Swift PR 并按同一批能力重写了一遍，两套实现的能力面已经基本重合；继续维护平行实现
意味着为 99% 自己用不到的 API 付出持续的对齐成本。收缩后 fork 的增量从约 17000 行降到
CLI 的 1059 行加上两处 C++ 补丁。

## 动机

### 上游关闭了 PR 并重写

上游在 commit `9a9036d`（2026-09-08，"Implement Swift bindings and native addon support
across all domains"）里重写了 Swift bindings，commit message 保留了
`Co-authored-by: Mx-Iris`。重写的依据是 `docs/reviews/pr-6-swift.md`，该文档针对本 fork 的
PR head `25b002a` 复现了 10 个缺陷。

### 自用率与维护面严重失衡

`idax` CLI 共 1059 行，只调用了 16 个 IDAX API：`Database` 6 个、`Analysis.wait` 1 个、
`DyldCache` 9 个。而本 fork 维护的 Swift bindings 是 48 个文件、14356 行，覆盖 41 个域。
其余 API 从未在本仓库内被调用过。

### 差异化优势已经消失

收缩决定的前提是"上游没有的能力"确实所剩无几。逐项查证结果见下一节：dyld 共享缓存解析、
microcode 快照、分支语义分类这三处曾被认为是 fork 的独有能力，实际上上游都已具备等价物，
且其中两处比 fork 的实现更完整。

## 前期调研

以下每条均在 2026-09-12 至 2026-09-13 查证，对比基线为 `git merge-base HEAD upstream/master`
= `cfa1eca`（本 fork 自该点起有 125 个 commit）。

### 两套实现的体量

| 项目 | 本 fork | 上游重写版 |
|---|---|---|
| Swift 源码 | 14356 行 / 48 文件 | 14253 行 / 85 文件 |
| Swift 专属 C++ bridge | 无（扩展 Rust shim 2178 行） | 6750 行（`bindings/swift/bridge/`） |
| 声明对账数据 | 无 | 66172 行（`bindings/swift/api_mapping/`） |
| 生成与校验脚本 | 无 | 1128 行（`bindings/swift/scripts/`） |

### dyld 共享缓存：公开接口完全一致

`include/ida/dyld_cache.hpp` 两边的函数一个不多一个不少：`is_available`、两个
`list_modules` 重载、`load_module`、`load_section`、`load_dyld_header`、
`load_branch_islands`、`load_branch_mappings`、`load_global_offset_tables`、
`load_gaps`、`load_cache_data`。

实现行数差异（`src/dyld_cache.cpp`：本 fork 787 行，上游 316 行）的构成：

- **IDA 9.3 兼容层，对 IDA 9.4 是死代码**。通过 netnode（IDA 数据库内的键值存储）直接驱动
  dscu 插件、预填标记绕过图形界面选择框的那套逻辑，整块包在
  `#if IDA_SDK_VERSION < 940` 里，独立块 155 行，加上各函数内的 `#else` 分支超过 200 行。
  上游直接放弃 9.3，只走 IDA 9.4 的公共缓存服务接口。
- **9.4 路径上两边实质等价**。`load_module` 都是 `get_image_index` → `load_image` → 验证。
  本 fork 多一步事后 `is_image_loaded` 确认，上游是事前跳过已加载项并多了绝对路径校验。
- **现代镜像表解析上游已有**。上游的离线 `list_modules(cache_path)` 同样按
  "现代表（偏移 0x1c0/0x1c4）→ 旧表（0x18/0x1c）→ 文本镜像表（0x88/0x90）"三级回退，
  与本 fork commit `09f5600` 的修复同路。

**被证伪的假设**：`include/ida/dyld_cache.hpp` 中 `load_module` 的文档曾声称本实现能加载
上游加载不了的模块（只存在于新格式 `dyld_cache_image_text_info` 表中的镜像）。该优势只在
IDA 9.3 分支成立——绕过选择框的逻辑在 9.4 分支里根本不存在，因为 9.4 的公共服务自己处理了
新格式镜像表。

### microcode：上游的更完整

本 fork 的 `ida::microcode`（`include/ida/microcode.hpp` 257 行 + `src/microcode.cpp`
529 行）提供 `Maturity`、`BlockKind`、`Operand`、`Instruction`、`Block`、
`FunctionSnapshot`、`snapshot(address, maturity)`。

上游把同一批能力放在 `ida::decompiler` 下（上游 review 引用其 Decision 19.39），有
`MicrocodeMaturity`（`include/ida/decompiler.hpp:410`）、`MicrocodeFunction` 入口
（同文件 1712 行）、`MicrocodeOperand`、`MicrocodeInstruction`、`MicrocodeRegisterRange`、
`MicrocodeSwitchCase`、`MicrocodeCallArgumentProperties`、`MicrocodeOpcode`、
`MicrocodeApplyResult`，并多出本 fork 没有的 `call_argument_properties`、
`call_return_operands`、`nested_instruction`、`referenced_operand` 等字段。

### 分支语义分类：本 fork 已回移上游版本

上游 review 第 9 条指出 x86 的 LOOP、LOOPE、LOOPNE、JECXZ 被归为同一条件。本 fork 已在
commit `8513324`（"Classify branch conditions from itype, not from disassembly text"）
修复，`7d79c1e` 则回移了上游的 microcode 语义元数据方案。

### 仍存在于本 fork 的已确认缺陷

逐一核对上游 review 的 10 条，以下 3 条在本 fork 当前分支上仍然成立：

1. **处理器模块的可选回调不派发**（`bindings/swift/Sources/IDAX/Processor.swift:497-506`）。
   `isCall` 等只有 protocol extension 里的默认实现，没有 protocol 声明。原生 trampoline
   通过 `any ProcessorModule` 调用，因此实现方的重写被忽略，永远返回默认值。
2. **Appcall 执行器返回码反了**（`bindings/swift/Sources/IDAX/Debugger.swift:467`、`472`）。
   Swift trampoline 成功返回 1、回调返回 nil 时返回 0；而 C 侧
   `bindings/rust/idax-sys/shim/idax_shim.cpp:9049` 判定 `if (cb_rc != 0)` 为失败。
   成功被当成失败，失败被当成成功且读到零值返回。
3. **Appcall 回调对象泄漏**（`bindings/swift/Sources/IDAX/Debugger.swift:916`）。
   注册时 `passRetained`，只在注册失败路径 release；cleanup trampoline（同文件 480 行）用
   `takeUnretainedValue` 且不释放。C 侧 `~CAppcallExecutor` 调用 cleanup 之后没有任何
   一方释放该引用。

### 上游确实没有的能力

`list_input_formats` —— 列出 IDA 会为某个输入文件提供哪些加载器，通用（fat）Mach-O
每个架构切片一条。上游 `include/ida/database.hpp` 中不存在该声明。配套的
`RuntimeOptions::input_format` 字段同样是本 fork 新增。

牵连范围经查证比预想的小：

- CLI 的 `binary` 子命令**不**使用 `list_input_formats`。它自己解析 Mach-O 胖头
  （`bindings/swift/Tools/CommandLineCore/MachOFatHeader.swift`），只把选中切片的格式名
  赋给 `runtimeOptions.inputFormat`
  （`bindings/swift/Tools/CommandLineCore/BinaryDatabaseCreator.swift:119`）。
- `list_input_formats` 只服务于 `formats` 这一个诊断子命令。
- 本 fork 另外新增的 `save_to` 与结构化 `open(path, OpenOptions)` 属于重复实现：上游
  `include/ida/database.hpp:225` 已有 `save_to`，其 `open(path, mode, intent)` 已覆盖
  `OpenOptions` 的用途。

### 上游的包装方式

上游 `Package.swift` 用 `.systemLibrary(name: "CIDAX", pkgConfig: "idax-swift")`，
消费者必须先用 CMake 构建 `idax_swift_native` 归档并生成 pkg-config 元数据，再设置
`PKG_CONFIG_PATH` 才能 `swift build`。其 `bindings/swift/CONTRACT.md` 明确把"清单中不含
unsafe linker flags"列为验收条件。本 fork 走的是 XCFramework 加预编译归档路线，
`swift build` 开箱即用。

## 提议方案

把 fork 的定位从"平行实现一套 Swift bindings"改为"上游之上的一个命令行工具"。

收缩后 fork 相对上游 master 的全部增量：

1. **`idax` 命令行工具**（`bindings/swift/Tools/`，1059 行）。三个子命令：`formats`
   （列出 IDA 提供的加载器）、`binary`（从二进制建库，含胖二进制选架构）、`dyld-cache`
   （从 dyld 共享缓存建库）。调用点改为上游的 Swift API 命名。
2. **两块 C++ 补丁**，尽量隔离以减小同步冲突面：
   - `RuntimeOptions::input_format` 字段及其在初始化路径中的消费点。**无法隔离**——该字段
     必须加进上游既有的结构体。
   - `InputFormat` 类型与 `list_input_formats()`。放入 fork 专属的独立头文件与源文件，
     不侵入上游的 `database.hpp` / `database.cpp`。
3. **预编译产物与安装脚本**（`bindings/swift/scripts/`），让 CLI 不必每次都跑一遍 CMake。
4. **fork 文档目录** `docs/fork/`，含本提案与已裁决清单。

### 非目标

- 不修那 3 个已确认缺陷。承载它们的代码本次即被删除，上游对应实现中已无此问题。按项目的
  code-review 规则，"不修"的裁决写进 `docs/fork/adjudicated-findings.md` 留档。
- 不把 CLI 或 `list_input_formats` 提交给上游。
- 不保留 `ida::microcode` 命名空间，也不为它做兼容外观。
- 不再维护 `.agents/fork/` 下的七份镜像账本。
- 不改变 CLI 现有的子命令名与参数——命令行接口就是本工具的用户界面，改名即破坏性变更。
- 不追求在 fork 内复刻上游的声明对账体系（`api_mapping/`、inventory 脚本）。fork 不再有
  需要对账的 Swift 表面。

## 详细设计

### 保留的 C++ 补丁

无法隔离的部分，直接加在上游结构体里（一个字段）：

```cpp
// include/ida/database.hpp — 上游文件，仅此一处侵入
struct RuntimeOptions {
    bool quiet{false};
    PluginLoadPolicy plugin_policy{};
    /// InputFormat::name of the loader to use for files opened afterwards.
    /// Empty lets IDA choose, which for a universal Mach-O means the first
    /// slice in the file.
    ///
    /// This belongs to initialisation, not to open(), because IDA parses it
    /// from the process command line: `idat` is a thin shell over
    /// `init_library(argc, argv)` and the format reaches the loader that way.
    /// Passing it later through `open_database`'s argument string selects the
    /// right loader but corrupts teardown.
    std::string input_format;
};
```

可隔离的部分，移入 fork 专属文件：

```cpp
// include/ida/fork/input_format.hpp — fork 专属，上游永不存在此路径
namespace ida::database {

/// A loader IDA is willing to use for a given input file.
///
/// A universal ("fat") Mach-O yields one entry per architecture slice, in the
/// order the slices appear in the file.
struct InputFormat {
    /// Name IDA displays for this format, carrying its own ordinal for
    /// multi-slice inputs (for example `Fat Mach-O file, 2. ARM64e-pauth1`).
    /// Pass it back verbatim through RuntimeOptions::input_format to select it.
    std::string name;
    /// Processor module this format wants (for example `arm`, `metapc`).
    std::string processor;
    /// Loader module that produced this entry.
    std::string loader_path;
    /// True when the loader treats the input as an archive of members.
    bool archive_loader{false};
};

/// List the formats IDA would offer for `path`, in IDA's own order.
/// Requires an initialised library. Returns an empty list when no loader
/// recognises the input.
Result<std::vector<InputFormat>> list_input_formats(std::string_view path);

} // namespace ida::database
```

### 删除的部分

| 路径 | 行数 | 理由 |
|---|---|---|
| `bindings/swift/Sources/IDAX/` | 14356 | 改用上游的 Swift bindings |
| `bindings/swift/Sources/CIDAX/` | 63 | 上游自带 shim 头与 modulemap |
| `bindings/swift/Tests/IDAXTests/` | — | 测的是被删除的 bindings |
| `bindings/rust/idax-sys/shim/` 的 2178 行扩展 | 2178 | 上游 shim 已覆盖 |
| `include/ida/microcode.hpp`、`src/microcode.cpp` | 786 | 上游 `ida::decompiler` 更完整 |
| `src/dyld_cache.cpp` 的 9.3 兼容层 | 200+ | 目标运行时是 IDA 9.4 |
| `include/ida/database.hpp` 的 `save_to`、`OpenOptions` | — | 上游已有等价物 |

`src/decompiler.cpp`、`src/instruction.cpp` 的改动逐块比对后并入上游版本或删除。

### CLI 的调用点适配

16 个调用点改名，已知差异：

| 本 fork | 上游 |
|---|---|
| `DyldCache.listModules(in:)` | `DyldCache.listModules(cachePath:)` |
| `DyldCache.isAvailable()` → `Bool` | `DyldCache.isAvailable()` → `throws(IDAError) -> Bool` |
| `Database.initialize()` | `Runtime.initialize(arguments:options:)` |

上游的 `Runtime` 不提供 actor 隔离保证，其契约要求调用方自己保证所有 SDK 调用在初始化线程上。
CLI 的 `ParsableCommand.run()` 在进程主线程执行，该条件成立。本 fork 原有的
`defaultIsolation(MainActor)` 编译期约束随 bindings 一并移除。

## 替代方案考量

- **继续维护整套平行 bindings**。否：99% 的 API 自己不用，3 个已确认缺陷要自己修，上游每次
  演进都要重新对齐。
- **把 CLI 整个提 PR 给上游，fork 用完即弃**。否：CLI 引入 `swift-argument-parser` 外部依赖，
  上游的包装契约明确排斥非必要依赖；上游刚拒过一次大 PR。
- **CLI 拆成独立仓库，依赖上游 idax**。否：`RuntimeOptions::input_format` 是 C++ 层的东西，
  独立仓库无处安放，仍需保留一个 fork，等于多管一个仓库。
- **把 `list_input_formats` 单独提 PR 给上游**。否（用户决定）：需要按上游风格重写——补声明
  清单、`api_mapping` 条目、契约文档，工作量不小而收益仅是省下一个独立文件的同步成本。
- **保留 `ida::microcode` 作为上游 `ida::decompiler` 的薄封装**。否：多一层要跟着上游变动
  维护的代码，而 fork 内没有调用方。
- **改用上游的 pkg-config 包装方式**。否：CLI 是日常工具，装一次用很久，不应每次重装或换机器
  都完整跑一遍原生构建。
- **砍掉 `formats` 子命令以求 fork 的 C++ 增量归零**。否：它是 `binary` 子命令的配套排障
  工具，架构没对上时用它看 IDA 自己的判断；C++ 实现已经写好，维护成本只是同步时保留一个
  独立文件。

## 影响

### 用户可见变化

CLI 的三个子命令名、参数与输出格式全部不变。`idax formats`、`idax binary`、
`idax dyld-cache` 的调用方式与收缩前一致。

内部实现从本 fork 的 Swift bindings 切换到上游的，属于不可见变更。唯一可能观察到的差异是
错误信息文本——上游的 `IDAError` 携带其自己的 message 与 context 措辞。

### 可发现性

不涉及新功能，无需引导。`idax --help` 的子命令列表不变。

### 数据与配置兼容

本工具不持有偏好设置或缓存。已生成的 `.i64` 数据库由 IDA 自身格式决定，不受本次改动影响。

### 平台与最低版本

目标运行时仍是 IDA Professional 9.4。最低 macOS 版本由上游 `Package.swift` 决定
（`.macOS(.v13)`），与本 fork 当前一致。

放弃 IDA 9.3 兼容是本次的实质变化：上游只支持 9.4 及以上的公共缓存服务接口。

### 发布

不涉及权限、entitlement 或隐私清单。CLI 通过 `bindings/swift/scripts/` 下的安装脚本分发，
不经 App Store 或公证流程。

## 落地步骤

1. 打归档标签指向当前 `feat/swift-bindings` 的 HEAD 并推到 `origin`，保留 125 个 commit 的
   完整历史。
2. 建立 `docs/fork/adjudicated-findings.md`，登记 3 个不修的缺陷及理由。
3. 合并上游 master，解决冲突时按本提案的删除清单取舍。
4. 移除 Swift bindings、CIDAX、IDAXTests、Rust shim 扩展、`ida::microcode`、
   `save_to` / `OpenOptions` 重复实现。
5. 把 `InputFormat` 与 `list_input_formats` 移入 `include/ida/fork/input_format.hpp` 与
   对应源文件；`RuntimeOptions::input_format` 保留在上游结构体内。
6. 逐块比对并处理 `src/decompiler.cpp`、`src/instruction.cpp`、`src/dyld_cache.cpp` 的改动。
7. CLI 的 16 个调用点适配上游 API 命名，`swift build` 与 `IDAXCommandLineTests` 通过。
8. 调整 `Package.swift`：CLI 依赖上游 `IDAX` target，保留预编译产物路线的构建与安装脚本。
9. 停用 `.agents/fork/` 七份账本，在 `docs/fork/README.md` 说明其冻结时点与后续记录位置。
10. 端到端验证：对一个 dyld 共享缓存和一个胖 Mach-O 各跑一遍建库，与收缩前的输出对照。

**收尾时必须判断两件事**（结果写进决策日志）：

- 要不要配套专题文章。候选：CLI 的使用指南（子命令、架构选择的行为）；实现说明（输入格式
  为什么只能在初始化时传、fork 补丁为什么这样切分）。
- 有没有引入新术语。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-09-13 | Created as Draft | 上游关闭 Swift PR 并重写后，评估本 fork 是否还有维护必要 |
| 2026-09-13 | CLI 留在 fork | 否决"整个提 PR 给上游"（CLI 带 `swift-argument-parser` 依赖，上游包装契约排斥）与"拆独立仓库"（`RuntimeOptions::input_format` 无处安放） |
| 2026-09-13 | 跟上游代码，停用 fork 账本 | 收缩后增量只剩 CLI 与两块补丁，七份镜像账本的写入成本远超收益；否决"代码与账本都继续维护"和"钉住某个上游版本" |
| 2026-09-13 | 3 个已确认缺陷不修，写入已裁决清单 | 承载代码本次即删除，上游对应实现已无此问题；否决"先修好再弃用"与"修完提 PR"（上游已无对应代码） |
| 2026-09-13 | 额外的 C++ 改动全部弃用 | microcode、decompiler ctree 导航、instruction 分支语义上游均有等价物且更完整；否决"保留 `ida::microcode` 作为薄封装" |
| 2026-09-13 | 保留预编译产物路线 | CLI 是日常工具，不应每次重装都跑完整 CMake；否决"改用上游 pkg-config"与"只留开发者模式" |
| 2026-09-13 | `list_input_formats` 不提 PR，永久留在 fork | 用户决定，否决了提案作者"提 PR"的建议——按上游风格重写（声明清单、`api_mapping`、契约文档）工作量不小，而收益仅为省下一个独立文件的同步成本 |
| 2026-09-13 | 就地在 `feat/swift-bindings` 收缩，收缩前打归档标签 | 历史完整保留在 git 中，不多一条长期分支；否决"新开收缩分支"与"先合进 master 再收缩"（后者会把已知有缺陷的代码写进主干历史） |
| 2026-09-13 | fork 文档放 `docs/fork/` | 沿用项目现有 `docs/` 小写目录习惯，上游永不存在该路径故同步零冲突；否决全局默认的 `Documentations/` 与继续用 `.agents/fork/`（该目录本次停用） |
| 2026-09-13 | 保留 `formats` 子命令 | 它是 `binary` 的配套排障工具；否决"砍掉以求 C++ 增量归零"与"改用自己解析胖头的推测输出" |
| 2026-09-13 | Draft → Accepted | 用户批准，开始实施 |
