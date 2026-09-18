# Draft - 一次运行建多个 database，并把 IDA 的工作数据库挪出输入目录

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-09-18
- **最后更新**: 2026-09-18
- **所属愿景**: 无
- **关联提案**: [收缩为上游之上的命令行工具](draft-shrink-fork-to-cli.md)
- **实现分支 / PR**: `feat/swift-bindings`
- **配套文档**: [`docs/Tools/IDAXCommandLine.md`](../../Tools/IDAXCommandLine.md) —— 既有使用指南，随本次改动更新

## 摘要

两件事一起做，因为第二件是第一件的前提。

1. **`idax binary` 一次只能处理一个二进制。** 批量建库只能写 shell 循环，而循环里哪个失败了要自己数、自己重跑。本提案让它接受多个路径。
2. **IDA 把工作数据库放在输入文件旁边。** 打开输入时解包出来的 `.id0` / `.id1` / `.nam` / `.til` 落在输入文件所在目录。同一个 dyld shared cache 被两个 `idax` 进程同时打开，两份工作数据库写进同一个目录、互相覆盖，产出的库是坏的；而且没清理干净的残留会让此后任何一次打开该 cache 直接失败——这一条已经写在使用指南里，是实际踩过的坑。本提案让每次运行在自己的私有目录里打开输入。

只要允许并发，就必须先隔离，否则批量功能本身就是一台造坏库的机器。

## 方案

### 工作数据库能被挪到哪里：四种做法的实测结果

全部在本机用一个直接链 `libidalib` 的探针测过，判据统一：把输入所在目录设为**只读**，能打开成功就说明 IDA 没往那里写。

| 做法 | 结果 |
|---|---|
| 符号链接指向输入 | **不行**。`open_database failed`。IDA 把输入路径解析成真实路径后才决定工作数据库的位置；源目录改回可写即成功，且源目录 mtime 被改动 |
| `-o<路径>` 传给 `init_library` | **不行**。`init_library` 直接返回 2 拒绝该开关。同一探针不传 `-o` 时一切正常，传 `-T` 也正常，所以不是探针的问题 |
| `-o<路径>` 传给 `open_database` 的 args 参数 | **不行**。工作数据库确实挪到了目标目录（`.id0` / `.id1` / `.nam` / `.til` 都出现在那里），但随即 `FATAL ERROR: Oops! internal error 30500` 崩溃，解包文件留在原地。这与使用指南里记的"通过 open 的参数串传 `-T` 会毁掉 teardown"是同一类失败 |
| **硬链接指向输入** | **可行**。源目录只读时打开成功、退出码 0，源目录零写入。硬链接没有可解析的真实路径，IDA 只能写在链接旁边 |

`idat -o` 是能用的（`idat -B -o<别处>` 在只读源目录上退出码 0），但工具走的是 idalib，而 idalib 的两个入口都不接受它。所以方案取硬链接。

硬链接的代价是**必须与输入同卷**。`/Volumes/DyldSharedCaches` 已确认是 APFS、可写、支持硬链接。

### 工作数据库隔离

每次运行（`binary` 与 `dyld-cache` 都算）：

1. 选一个与输入**同卷**的父目录：`--work-dir` 指定的位置优先；否则系统临时目录（本机上 `/Applications` 之类与它同卷，够用）；两者都不同卷时退回输入文件所在目录。
2. 在其中建 `idax-work-<pid>-<uuid>/`，对输入文件建**同名**硬链接（同名是必须的，dyld cache 的分片 `.01` / `.atlas` / `.map` 靠基名找）。
3. dyld cache 另把同目录下同基名的分片文件一并硬链接过去，但**排除 IDA 数据库制品**（`.i64` / `.idb` / `.id0` / `.id1` / `.nam` / `.til` / `.asm`）——把上一次留下的残留链过去，正好会让 IDA 拒绝打开。
4. IDA 打开这个硬链接；`save_to` 仍写到用户指定的最终输出路径。
5. 运行结束（含失败路径）删除整个私有目录。

实际选中的目录会打印一行，出问题时不用猜。进程被强杀会留下一个 `idax-work-*` 目录，这一点写进使用指南，不做自动清理——扫描并删除别人的临时目录，风险比它解决的问题大。

输入位于只读卷时建不了硬链接，但那种情况今天也建不了库（IDA 需要在输入旁边写工作数据库），不算功能回退。

### 命令形态

`idax binary` 接受多个路径，不新增子命令：

```bash
idax binary AppA AppB AppC --output-dir /tmp/databases --jobs 4
```

- **单个输入**：行为与今天逐字一致，`--output` 照常可用，仍在本进程内完成。
- **多个输入**：`--output` 报错（一个路径装不下多份产出），改用 `--output-dir`（默认当前目录），每个输入产出 `<去掉扩展名的文件名>.i64`。
- `--arch`、`--overwrite`、`--skip-final-analysis` 对每个输入一律生效。
- `--jobs <n>`，默认 1。
- `--work-dir <dir>`，两个子命令都有。

不接受目录递归，不接受清单文件 —— shell 的 glob 已经覆盖绝大多数场景，而目录递归要额外定义一整套过滤规则（读 magic 判断、跳过非 Mach-O、要不要跟随符号链接、`.app` 里的 `Frameworks` 算不算），边界情况远多于收益。

### 执行模型：一个输入一个子进程

多输入时父进程自己不建库，而是对每个输入重新执行自己的单输入形态（`Bundle.main.executableURL` 加上 `binary <单个路径> --output <路径>`）。理由：

- **`-T` 只在 `init_library` 上被接受，一个进程一次。** 不同输入要选不同的 fat slice，进程内循环做不到——这条约束已经写在使用指南的「Why the architecture is chosen before IDA starts」里。
- **崩溃隔离**：某个畸形输入把 IDA 打死，只死那一个 job，其余照跑。
- **失败可复现**：汇总里打印的失败 job 就是一条可以直接复制重跑的命令。

调度：`--jobs 1` 时子进程直接继承 stdout / stderr，输出与今天一样是实时的；`--jobs > 1` 时每个 job 的输出缓冲到它结束时整块打印并冠以输入路径，避免多进程输出交错成无法阅读的一团。

失败策略：不中断，跑完全部输入，最后给一张成败汇总；只要有失败，退出码非零。

### 开工前一次性做完静态检查

在启动任何 job 之前全部检查完，任何一条不过就整批不开工：输入存在且不是目录、输出目录存在、多个输入产出同一个输出路径、未加 `--overwrite` 时输出已存在。撞名（两个不同 bundle 里的 `Contents/MacOS/App` 都会变成 `App.i64`）直接报错而不是自动加后缀——自动改名会让"哪个库对应哪个输入"变成猜。

花一小时分析完才发现输出撞名，是这批检查要防的唯一一件事。

### 改动清单

| 路径 | 动作 |
|---|---|
| `bindings/swift/Tools/CommandLineCore/BinaryDatabaseCreator.swift` | 变参输入、`--output-dir`、`--jobs`、`--work-dir`；单输入路径接上工作目录隔离 |
| `bindings/swift/Tools/CommandLineCore/BinaryDatabaseBatchPlan.swift` | 新增。纯计划类型：输入 → job 列表、输出路径、撞名与已存在检查 |
| `bindings/swift/Tools/CommandLineCore/DatabaseJobRunner.swift` | 新增。子进程调度、输出缓冲、成败汇总 |
| `bindings/swift/Tools/CommandLineCore/WorkingDatabaseDirectory.swift` | 新增。同卷私有目录、硬链接、分片选择、清理 |
| `bindings/swift/Tools/CommandLineCore/DynamicLinkerSharedCacheDatabaseCreator.swift` | 接上同一套隔离，含分片硬链接 |
| `bindings/swift/Tests/IDAXCommandLineTests/` | 新增计划、隔离与调度的单元测试（不需要 IDA 运行时）；既有 dyld-cache 测试改用 `parse(...)` 构造命令 |
| `docs/Tools/IDAXCommandLine.md` | 更新用法、批量行为、工作目录隔离的说明 |

**上游侵入为零。** `bindings/swift/Tools/` 与 `docs/Tools/` 上游都不存在（已核对 `upstream/master`），本次不碰 `Package.swift`，也不碰任何上游 C++。

### 实施中的发现：只读的 System 卷根本不允许硬链接

`/bin`、`/usr`、`/System` 下的文件建不了硬链接——硬链接要改的是 inode 的链接计数，而
System 卷是密封只读的（`You can't save the file "ls" because the volume "Macintosh HD"
is read only`）。而且 `st_dev` 判不出来：macOS 给 System 卷和 Data 卷报同一个设备号
（`/bin`、`/Applications`、`/private/var/folders` 实测都是 `16777233`），所以事前无法预判，
只能试了才知道。

处理方式是**链接失败就复制**，并在复制前打印一行说明（大文件会卡一会儿，无声的停顿更糟）。
这不是退化：改动前 `idax binary /bin/ls` 同样建不了库（实测旧版报 `open_database failed`），
因为 IDA 也没法把工作数据库写进只读目录。现在它能了。

### 实施中的发现：父进程的输出会被缓冲到最后

串行模式下 `==> [1/3] …` 这类横幅原本全部堆在子进程输出之后才出现。子进程直接写继承来的描述符
并在退出时刷新，而父进程的 stdout 在不是终端时是全缓冲的。加一次 `fflush` 解决。

### 验证结果

| 步骤 | 结果 |
|---|---|
| 单元测试（不需要 IDA 运行时） | 通过，74 tests / 7 suites，原始退出码 0 |
| 单输入建库，**源目录只读** | 通过，退出码 0；改动前同样条件下失败 |
| 批量 3 个二进制，串行 | 通过，3/3 成功 |
| 批量 4 个二进制，`--jobs 3` | 通过，4/4 成功，输出分块未交错 |
| 撞名 / 多输入配 `--output` / 输出已存在 / `--jobs 0` | 四项都在开工前被拒，退出码 64 |
| 单个 job 失败（对 thin 二进制传 `--arch x86_64`） | 其余照跑，汇总列出失败与可复制的重跑命令，退出码 1 |
| `/bin/ls` 等只读卷输入 | 通过，走复制回退；改动前失败 |
| dyld cache 建库（26.2，libobjc.A） | 通过，18 秒，392 MB，cache 目录零残留 |
| **两个进程同时对同一个 cache 建库** | **通过，两个都成功**；同样场景下旧版有一个报 `open_database failed` |

### 不问而定的假设

- 失败不中断、跑完汇总、有失败即非零退出码。
- 批量的默认输出目录是当前目录，与今天单输入的默认一致。
- 隔离对 `binary` 也默认打开，不只给 `dyld-cache`：并发处理同一个输入同样会撞。
- 隔离没有开关可以关掉。留一个"关掉隔离"的选项只会让人在出问题时把它关掉来"试试"，而它正是防止出问题的东西。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-09-18 | Created as Draft | 用户要求：给 CLI 加功能，一次生成多个二进制的 database；并指出 dyld cache 不应就地生成，否则多个 CLI 并发会写坏库 |
| 2026-09-18 | 不用符号链接 | 实测 IDA 把输入路径解析成真实路径后才决定工作数据库位置，符号链接挡不住并发互写 |
| 2026-09-18 | 不用 IDA 的 `-o` 开关 | 实测 idalib 两个入口都不接受：`init_library` 返回 2 拒绝；`open_database` 的 args 参数能挪走工作数据库但随即 `internal error 30500` 崩溃，与文档里 `-T` 走该参数的同类失败一致。`idat -o` 可用不代表 idalib 可用 |
| 2026-09-18 | 改用同卷硬链接 | 硬链接没有可解析的真实路径，实测源目录只读时打开成功且零写入；代价是必须同卷，`/Volumes/DyldSharedCaches` 已确认是支持硬链接的可写 APFS |
| 2026-09-18 | 分片硬链接排除 IDA 数据库制品 | 同基名前缀会把上一次运行留下的 `.id0` 等残留一并链过去，而 IDA 遇到旁边已有解包数据库就拒绝打开——正是要修的那个坑 |
| 2026-09-18 | 不自动清理残留的 `idax-work-*` 目录 | 扫描并删除不属于本次运行的临时目录，风险大于收益；改为写进使用指南 |
| 2026-09-18 | 扩展 `idax binary` 接受变参，而不是新增 `batch` 子命令 | 不引入第二套词汇；`--arch` / `--overwrite` / `--skip-final-analysis` 全部原样复用，单文件用法一字不变 |
| 2026-09-18 | 每个输入一个子进程，而非进程内循环 | `-T` 只在 `init_library` 上被接受、一个进程一次；另外换来崩溃隔离和可直接复制重跑的失败命令 |
| 2026-09-18 | `--jobs` 默认 1 | 输出顺序确定、内存可控、不会意外撞上 IDA 授权的并发上限；要吞吐量的人显式提高 |
| 2026-09-18 | 输入只接受命令行上列出的路径 | 目录递归要定义一整套 Mach-O 过滤规则，边界情况远多于收益；shell glob 已覆盖常见场景 |
| 2026-09-18 | `dyld-cache` 这次只修隔离，不加"每个 image 一个库" | 隔离是并发安全的前提、范围小且可验证；产出形态的变更是另一件事，等有需要再单独提 |
| 2026-09-18 | Draft → Accepted | 用户批准；`-o` 探针结论出来后按硬链接路线重写了方案 |
| 2026-09-18 | 链接失败时复制输入，而不是报错退出 | 只读的 System 卷不允许硬链接，且 `st_dev` 事前判不出来（System 与 Data 卷共用一个设备号）。复制让 `/bin/ls` 这类输入从"完全建不了库"变成"能建"，不是退化 |
| 2026-09-18 | 测试改用 `parse(...)` 而非直接构造命令再赋值 | 直接构造会让未赋值的 `@Option` 没有存储，读到就 trap——加 `--work-dir` 时一个既有测试正是这么崩的 |
| 2026-09-18 | In Progress → Implemented | 全部验证通过，含"两进程并发同一 cache"的前后对比 |
| 2026-09-18 | 收尾两问：配套文档更新既有使用指南，不新增术语表条目 | `docs/Tools/IDAXCommandLine.md` 是这个工具唯一的使用指南，新增"Where IDA's working database goes"一节并改写 `idax binary` 段落即可，另起一份会分散；working database、hard link、sealed system volume 分别是 IDA、操作系统与 Apple 的既有说法，非本项目自创 |
