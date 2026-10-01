# Draft - `idax binary` 接受 bundle，加载其主二进制

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-10-01
- **最后更新**: 2026-10-01
- **关联提案**: [一次运行建多个 database，并把 IDA 的工作数据库挪出输入目录](draft-batch-database-creation.md)
- **实现分支 / PR**: `feat/swift-bindings`
- **配套文档**: [`docs/Tools/IDAXCommandLine.md`](../../Tools/IDAXCommandLine.md) —— 既有使用指南，新增「Bundles」一节

## 摘要

`idax binary` 和 `idax formats` 过去只接受文件，传 `Foo.app` 或 `Foo.framework` 会报「binary
does not exist」，用户得自己拼出 `Contents/MacOS/Foo` 或 `Versions/A/Foo`。本提案让两个子命令
直接接受 bundle：用 `Bundle.executableURL` 找到主二进制，此后与直接传该二进制完全等价。

实现过程中顺带修了一个由上一份提案引入的 bug：输入是符号链接时，工作数据库隔离会失效。分版本
framework 的 `Foo.framework/Foo` 本身就是符号链接，不修这个，本功能对 framework 就用不了。

## 方案

### 解析 bundle

新增 `BundleExecutable.executableFileURL(forInputAt:)`，在 `BinaryDatabaseBatchPlan` 里、
**任何由路径推导出来的东西之前**调用：输出名、撞名检查都基于解析后的主二进制。所以
`Foo.app` 与 `Foo.app/Contents/MacOS/Foo` 在每个方面都是同一个输入，同时传两者会被既有的撞名
检查拒掉。`idax formats` 用同一个函数。

`Bundle.executableURL` 的实测行为（本机 macOS 27）：

| 输入 | 结果 |
|---|---|
| `Xcode.app`、`Finder.app`、`.appex`、`.xpc` | `Contents/MacOS/<名字>` |
| 模拟器运行时里的 `MobileSafari.app`（iOS 扁平布局） | 顶层的 `MobileSafari` |
| `DVTFoundation.framework`（分版本） | `Foo.framework/Foo`，是指向 `Versions/Current/Foo` 的**符号链接** |
| `/System/Library/Frameworks/AppKit.framework` | 返回一个**悬空**的符号链接：macOS 11 起系统 framework 的二进制只在 dyld shared cache 里 |
| 模拟器运行时里的 `UIKit.framework` | 返回 `nil`，原因同上 |
| 普通目录 | `nil` |

于是有三种结果：找到且文件存在 → 加载；Info.plist 写了 `CFBundleExecutable` 但文件不在 →
报错并指向 `idax dyld-cache`；连可执行文件都没声明 → 报「是目录但不是带可执行文件的 bundle」。

空路径的检查从 `BinaryDatabaseCreationPlan` 挪到了 `BinaryDatabaseBatchPlan` 的循环开头：空
路径会被补全成当前目录，不先拦住就会报成「不是 bundle」。

### 顺带修复：符号链接输入让隔离失效

`FileManager.linkItem` 遇到符号链接时复制的是链接本身，不会给目标建硬链接（Apple 文档原文：
"If srcURL is (or contains) a symbolic link, the symbolic link is copied"），`copyItem` 也一样。
于是：

- **相对符号链接**（`Foo.framework/Foo` → `Versions/Current/Foo`）放进私有目录后悬空，IDA 打不开。
- **绝对符号链接**：IDA 先解析到真实路径，工作数据库又落回原目录，并发互写的问题回来了。

修法是在 `WorkingDatabaseDirectory.make` 开头先 `resolvingSymlinksInPath()`，私有目录的同卷
判断、链接名、dyld cache 分片的查找全都基于真实文件；`place(fileAt:as:)` 对每个文件（含分片）
也先解析一次。`binary` 与 `dyld-cache` 共用这段代码，一处修复覆盖两边。

这段代码由上一份提案引入，`master` 上没有，属于本分支内的回归。

### 不问而定的假设

- **输出库以主二进制命名，不以 bundle 命名**。传 bundle 与传其主二进制得到同名的库；代价是
  主二进制另有其名的应用（如 `Electron`）得到 `Electron.i64`，需要时用 `--output`。
- **不展开嵌套 bundle**：只加载主二进制，应用里的 `Frameworks/`、`PlugIns/` 不递归。
- 解析结果打印一行 `Loading the executable of <bundle>: <executable>`，由父进程打印；多输入时
  子进程拿到的已是主二进制路径，不会重复打印。

### 改动清单

| 路径 | 动作 |
|---|---|
| `bindings/swift/Tools/CommandLineCore/BundleExecutable.swift` | 新增。bundle → 主二进制，含两类报错 |
| `bindings/swift/Tools/CommandLineCore/BinaryDatabaseBatchPlan.swift` | 先解析 bundle 再推导输出名；空路径检查挪到这里 |
| `bindings/swift/Tools/CommandLineCore/BinaryDatabaseCreator.swift` | 帮助文本；计划带上 `bundleURL`；打印解析结果 |
| `bindings/swift/Tools/CommandLineCore/InputFormatLister.swift` | 接受 bundle |
| `bindings/swift/Tools/CommandLineCore/WorkingDatabaseDirectory.swift` | 符号链接修复 |
| `bindings/swift/Tests/IDAXCommandLineTests/BundleInputTests.swift` | 新增 11 个测试 |
| `bindings/swift/Tests/IDAXCommandLineTests/WorkingDatabaseDirectoryTests.swift` | 新增 2 个符号链接回归测试 |
| `docs/Tools/IDAXCommandLine.md` | 新增「Bundles」一节，补充符号链接说明 |

**上游侵入为零**：以上路径在 `upstream/master` 上都不存在（已核对）。

### 验证结果

| 步骤 | 结果 |
|---|---|
| 两个符号链接回归测试，修复前 | **失败**：链接被原样复制、分片一个也没找到；其余 74 个通过 |
| `IDAXCommandLineTests` 全部，修复后 | 通过，87 tests / 8 suites，原始退出码 0 |
| 单输入：分版本 framework（`SourceEditorRegExSupport.framework`，外置卷） | 通过，退出码 0；工作目录建在真实文件所在的 `Versions/A/` 下，结束后无残留 |
| 批量：`Dock.app` + 上述 framework，`--jobs 2` | 通过，2/2；`Dock` 选中 arm64e 切片 |
| `AppKit.framework` | 开工前被拒，退出码 64，提示改用 `idax dyld-cache` |
| 普通目录 | 开工前被拒，退出码 64 |
| `idax formats Dock.app` | 通过，列出两个切片与 IDA 的 loader |

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-01 | Created as Draft | 用户要求：传入的路径是 framework / bundle 时，直接找到主二进制加载，即 `NSBundle.executableURL` |
| 2026-10-01 | 用 `Bundle.executableURL`，不自己拼路径 | 实测它覆盖 `.app` / `.appex` / `.xpc` / iOS 扁平布局 / 分版本 framework；自己拼要重新实现 CFBundle 的布局判断 |
| 2026-10-01 | 解析放在推导输出名之前 | 让 bundle 与其主二进制在输出名、撞名检查上完全等价 |
| 2026-10-01 | 输出以主二进制命名 | 与直接传主二进制的结果一致；用户在批准方案时未提异议 |
| 2026-10-01 | 主二进制缺失单独报错并指向 `idax dyld-cache` | 系统 framework 是最常见的误用，而它们的 Info.plist 照样写着可执行文件名 |
| 2026-10-01 | 符号链接修复放进 `WorkingDatabaseDirectory`，不放进 bundle 解析 | 问题属于「任何符号链接输入」，`dyld-cache` 同样受影响；放在共用的放置逻辑里一处修全 |
| 2026-10-01 | Implemented | 单元测试与端到端验证见上；无新术语，配套文档为既有使用指南 |
