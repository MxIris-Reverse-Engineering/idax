# Draft - 在 Xcode GUI 里构建原生归档的 SwiftPM command plugin

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-09-18
- **最后更新**: 2026-09-18
- **所属愿景**: 无
- **关联提案**: [收缩为上游之上的命令行工具](draft-shrink-fork-to-cli.md)
- **实现分支 / PR**: `feat/swift-bindings`
- **配套文档**: 无独立文档 —— 用法并入 `CLAUDE.md` 的 Swift 构建段落

## 摘要

在 Xcode 里打开这个 SwiftPM 包时，包解析会报一条警告
`couldn't find pc file for idax-swift`。根因不是配置错误，而是
`Package.swift` 的预编译归档路线没有产物可用：`bindings/swift/.build-libs/libidax_swift_native.a`
不存在时，清单退回上游的 `.systemLibrary(pkgConfig: "idax-swift")` 分支，而 pkg-config
元数据同样没有生成过。消除它只需要跑一次 `bindings/swift/scripts/build-libs.sh`，但那是一条
终端命令——在 Xcode 里工作的人得切出去、手动 `export IDADIR`、再回来让 Xcode 重新解析包。

本提案给包加一个 SwiftPM command plugin，把这一步搬进 Xcode 的图形界面：在项目导航器里右键
包，选择该 plugin，批准一次写权限，即可完成原生归档构建。plugin 本身不含构建逻辑，只是
`build-libs.sh` 的调用层，负责补齐 Xcode 图形环境缺失的那部分上下文。

## 方案

### 新增与改动

| 路径 | 动作 | 归属 |
|---|---|---|
| `bindings/swift/Plugins/BuildNativeLibrary/BuildNativeLibrary.swift` | 新增 | fork 独有路径，上游没有 |
| `Package.swift` | 增加一个 `.plugin(...)` target 声明 | 上游也有此文件，但已是 fork 深度改造过的清单 |
| `bindings/swift/scripts/build-libs.sh` | **不改** | fork 独有文件，但无需改动 |
| `CLAUDE.md` | 补充用法与清缓存说明 | fork 独有文件 |

**不新增上游侵入点。** `Package.swift` 是唯一被改的上游文件，而它早已因预编译归档路线、
`idax` 可执行产品和 `CIDAXFork` 模块而与上游分叉（约 172 行差异），收缩提案已把它列为既定的
fork 偏离项。plugin 的实现代码全部落在上游没有的 `bindings/swift/Plugins/` 路径下。

### plugin 的职责

声明形态：

```swift
.plugin(
    name: "BuildNativeLibrary",
    capability: .command(
        intent: .custom(verb: "build-libs", description: "Build libidax_swift_native.a"),
        permissions: [
            .writeToPackageDirectory(reason: "..."),
            .allowNetworkConnections(scope: .all(ports: []), reason: "..."),
        ]
    ),
    path: "bindings/swift/Plugins/BuildNativeLibrary"
)
```

实现是一个薄转发层，与被删除的 `BuildXCFramework` 同一形态——真源仍是 shell 脚本，plugin
不复制任何构建逻辑。它只做三件图形环境下必须做、命令行下由 shell 自然提供的事：

1. **定位 `cmake`**。Xcode 启动的进程继承 launchd 的 PATH，其中不含 `/opt/homebrew/bin`。
   plugin 按 `/opt/homebrew/bin`、`/usr/local/bin`、`xcrun --find` 的顺序查找，找不到就以一条
   可读的错误终止，而不是让脚本报 `command not found`。
2. **定位 IDA 运行时目录**。同理，`IDADIR` 在 Xcode 环境里是空的
   （已实测 `launchctl getenv IDADIR` 无输出）。plugin 复用 `Package.swift` 中
   `idaRuntimeDirectory` 的发现顺序：先看环境变量，再扫 `/Applications/IDA*.app/Contents/MacOS`
   取版本号最大且含 `libida.dylib` 的那个，然后把结果作为 `IDADIR` 注入子进程环境。
3. **透传输出**。子进程的 stdout/stderr 直接继承，使 CMake 的进度出现在 Xcode 的 plugin
   结果窗口里，而不是构建结束后一次性吐出。

### 不问而定的假设

以下几处按默认档自行决定，若有异议请指出：

- **verb 命名为 `build-libs`**，与脚本同名，命令行 `swift package plugin build-libs` 与 GUI
  菜单项指向同一件事，不引入第二套词汇。
- **构建类型固定为脚本默认的 Release**。Xcode 的 plugin 菜单不提供参数输入框，GUI 路径只能定死
  一个；需要 Debug 的人走命令行传 `--build-type`。
- **接受一份重复的 IDA 运行时发现逻辑**。`Package.swift` 里已有一份，plugin 无法复用它——清单是
  独立编译单元。两者同构且各约十行，比把发现逻辑下沉进 `build-libs.sh`（那会改变脚本"必须显式
  设置 IDADIR"的既有契约，且影响命令行用户）代价更小。
- **声明网络权限**。`IDASDK` 当前未设置，CMake 会 FetchContent 下载固定 commit 的 SDK。不声明的话
  首次运行必然失败。
- **不动 `build-libs.sh`**。它对 IDADIR 的显式要求是命令行下的正确契约；缺失环境变量是图形环境
  特有的问题，由图形适配层解决。

### 已实测的可行性

在 `/tmp` 的最小探针包中，以与 Xcode 相同的沙盒条件运行 command plugin：

| 能力 | 结果 |
|---|---|
| 执行工具链之外的外部程序（`/opt/homebrew/bin/cmake`） | 通过，退出码 0 |
| 写包目录（声明权限并批准后） | 通过 |
| 写 `~/.cmake` | **被拒**，`Operation not permitted` |

第三项是唯一的残余风险：CMake 的 user package registry 位于 `~/.cmake/packages`。
`find_package` 只**读**它（沙盒允许读），写只发生在 `export(PACKAGE)` 调用时。本项目的
`find_package(idasdk)` 走 `CMAKE_PREFIX_PATH`，预期不触发写入，但需要在实施时跑一次完整构建
确认。构建产物目录 `bindings/swift/.cmake-build` 与 `.build-libs` 都在包目录内，已被授权覆盖。

### 验证结果

命令行路径全部实测通过。为贴近 Xcode 的真实条件，plugin 的两次运行都在
`env -u IDADIR -u IDASDK PATH="/usr/bin:/bin:/usr/sbin:/sbin"` 下进行——即模拟
launchd 环境，既无 `IDADIR` 也无含 Homebrew 的 PATH。

| 步骤 | 结果 |
|---|---|
| `swift package plugin --list` 列出 `build-libs` | 通过 |
| 模拟 Xcode 环境下自行定位 cmake 与 IDA 运行时 | 通过，两者均正确解析 |
| 沙盒内完整构建（含 FetchContent 下载 SDK） | 通过，退出码 0 |
| 产出 `bindings/swift/.build-libs/libidax_swift_native.a` | 通过，4.6 MB，arm64 |
| 清缓存后 `couldn't find pc file for idax-swift` 警告 | 消失，出现次数 0 |
| `swift build --product idax` | 通过，退出码 0 |
| `swift test --filter IDAXCommandLineTests` | 通过，45 tests / 4 suites，原始退出码 0 |
| 模拟 Xcode 注入 `--target` 的完整构建 | 通过，退出码 0 |
| **Xcode GUI 右键运行** | 修复 `--target` 后由用户在本机实测通过 |

`~/.cmake` 不可写这一残余风险未成为问题：CMake 配置与构建全程未触发对它的写入。

### 实施中的发现：Xcode 会注入 `--target`

用户在 Xcode 里首次运行时报 `ERROR: Unknown option: --target`。Xcode 运行 command plugin 前会弹出
对话框让用户勾选 target，并把结果作为 `--target <名字>` 传给 plugin；plugin 原样转发给
`build-libs.sh`，脚本不认识该选项即退出。**命令行调用不会注入这个参数，所以之前的验证全部漏掉了
它。**

修复采用 PackagePlugin 官方的 `ArgumentExtractor` 剥离该选项后再转发。这个 plugin 构建的是一个
包级归档，与选中哪个 target 无关，因此选择结果被直接丢弃而非映射成构建参数。

顺带确认：那次失败的输出里，plugin 在 Xcode 给的 PATH（只含 Xcode 工具链与系统目录、不含
Homebrew）下仍正确解析出了 `/opt/homebrew/bin` 的 cmake 与 IDA 运行时目录——发现逻辑在真实
GUI 环境中按设计工作。

### 实施中的发现：清单求值结果会被缓存

归档是否存在，是在**清单求值时**判定并写进缓存的。归档刚刚产出时，缓存里的答案仍是"不存在"，
于是链接行缺少 `-L` 搜索路径，构建以
`ld: warning: Could not find or use auto-linked library 'idax_swift_native'` 加一串
undefined symbols 失败，且 `couldn't find pc file for idax-swift` 警告依旧出现——看上去像 plugin
没生效，实际上归档已经建好了。

关键在于 **`swift package reset` 不足以解决**：它清的是 scratch 目录，而 SwiftPM 查的是
`~/Library/Caches` 下的 shared manifest cache。实测有效的做法是 `swift package purge-cache`
（命令行）或 `File > Packages > Reset Package Caches`（Xcode）。这一条已写进 plugin 的收尾提示
与 `CLAUDE.md`，否则每个第一次用它的人都会撞上同一堵墙。

### 顺带澄清的一件事

被删除的 `bindings/swift/Plugins/BuildXCFramework/BuildXCFramework.swift`
**从未在任何一版 `Package.swift` 里被声明过**（已遍历该文件的全部历史版本确认）。它的文件头注释
写着"restored to satisfy Package.swift target resolution"，但对应的 target 声明并不存在，因此它
在 Xcode 里从来没有出现过。本提案是第一次真正给这个包接上 plugin 入口，不是恢复旧能力。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-18 | Created as Draft | 用户要求：加一个 plugin 用来在 Xcode GUI 里跑 build-libs 脚本 |
| 2026-09-18 | plugin 作为薄转发层，构建逻辑留在 `build-libs.sh` | 脚本是既有真源；在 plugin 里重写会产生两份需要同步的实现，正是被删除的 XCFramework 路线失效的原因 |
| 2026-09-18 | 发现逻辑放进 plugin 而非下沉到脚本 | 保持脚本对命令行用户的显式契约不变；缺失环境变量是 GUI 特有问题 |
| 2026-09-18 | 命名为 `BuildNativeLibrary` 而非沿用 `BuildXCFramework` | 产物是静态归档不是 XCFramework，沿用旧名会误导 |
| 2026-09-18 | Draft → Accepted | 用户批准，开始实施 |
| 2026-09-18 | 收尾提示同时给出 Xcode 与命令行两种清缓存做法 | 实施中实测发现 `swift package reset` 无效，必须 `purge-cache`；只提 Xcode 会让命令行用户卡住 |
| 2026-09-18 | Accepted → In Progress | 代码完成，命令行验证全部通过；仅余 Xcode GUI 一步待用户在本机确认 |
| 2026-09-18 | 用 `ArgumentExtractor` 丢弃 Xcode 注入的 `--target` | 该 plugin 产出包级归档，与 target 选择无关；直接转发会让脚本因未知选项退出。命令行验证无法覆盖此路径，由用户的首次 GUI 实测暴露 |
| 2026-09-18 | In Progress → Implemented | 用户在 Xcode GUI 中实测通过，最后一项验证补齐 |
| 2026-09-18 | 收尾两问：不写独立配套文档，不新增术语表条目 | 用法只有"右键跑一下 / 跑完清缓存"两句，并入 `CLAUDE.md` 的 Swift 构建段落即可，单独成文反而分散；command plugin、manifest cache、sandbox 均为 SwiftPM 既有术语，非本项目自创 |
