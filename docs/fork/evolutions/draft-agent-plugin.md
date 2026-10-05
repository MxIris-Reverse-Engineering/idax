# Draft - 以插件形式提供 `idax` 的 agent skill

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-10-05
- **最后更新**: 2026-10-05
- **关联提案**: [一次运行建多个 database，并把 IDA 的工作数据库挪出输入目录](draft-batch-database-creation.md)、[`idax binary` 接受 bundle，加载其主二进制](draft-bundle-input.md)
- **实现分支 / PR**: `feat/swift-bindings`
- **配套文档**: 无新增 —— 安装方法写进 `README.md` 的 CLI 一节，完整用法仍以 [`docs/Tools/IDAXCommandLine.md`](../../Tools/IDAXCommandLine.md) 为准

## 摘要

教 agent 使用 `idax` 的那份说明，原本是维护者本机全局逆向 skill 里的一份 reference：别人装不到，
CLI 改了也没人同步。现在把它搬进本仓库，做成 Claude Code 与 Codex 都能从 GitHub 安装的插件
`idax`（skill 名 `idax-cli`），随 CLI 一起维护。

## 方案

- **布局**与 MachOSwiftSection 的 `swift-section` 插件同构：`AgentPlugins/idax/` 下放两个工具的
  插件清单（`.claude-plugin/plugin.json`、`.codex-plugin/plugin.json`）和
  `skills/idax-cli/SKILL.md`；仓库根目录放两个工具的 marketplace 清单
  （`.claude-plugin/marketplace.json`、`.agents/plugins/marketplace.json`）。插件只含 skill，
  `idax` 本身仍按 README 安装。
- **内容**取自原 reference，并入了原逆向 skill 正文里重复的工具细节（fat 二进制选 slice 的原因、
  bundle、批量、dyld cache 参数、退出码与成败判读），去重后逐条对照当前 `idax help` 与
  `bindings/swift/Tools/` 源码核对。去掉了本机路径与对本机 skill 的引用；原文按日期写的版本要求
  （「2026-10-01 以后的 idax」）改成陌生人也能判断的两个信号：给 bundle 报
  `The binary does not exist`、运行时没有 `Working database directory:` 这一行。核对中改正与补充：
  - 现行 `idax` 打开的是私有目录里的硬链接，**不受输入旁残留的 `.id0` 等文件影响**；原文「残留会
    毒害此后对该 cache 的每一次运行」只对 GUI、`idat`、MCP 会话与旧版 idax 成立。
  - 退出码 64 不只表示参数被拒：打开 IDA 之后的拒绝（镜像名在 cache 里无匹配、无法确认加载的架构）
    同样是 64，因为 swift-argument-parser 把任何 `ValidationError` 都映射成 64；IDA 自身失败与批量
    中有失败才是 1。
  - 补上了 `--output` 与 `--output-dir` 不能同时用、`--output-dir` 必须已存在、`--overwrite` 只在
    加载与分析都成功后才删旧库、`dyld-cache` 不给 `--output` 时按 `A+B+C.i64` 命名、IDA 9.4 本就
    加载 dyld header 等事实。
- **原 reference 末尾「Working on idax itself」的六条 idalib 约束**是写给改 idax 的人的，不进插件，
  并入 `CLAUDE.md` 新增的「idalib constraints the tool is built around」一节，每条指向测得它的记录
  （binary-mode 计划、批量提案、bundle 提案）。其中「`link(2)` 会跟随符号链接」一条在落地时于本机
  macOS 27 上重新实测过。
- **同步规则**写进 `CLAUDE.md` 的 Mandatory update protocol：改动插件所描述的 CLI 表面时，同一提交
  更新 skill，并在两份插件清单里升 `version` —— 两个工具都只在版本号变化时才更新已装的插件。
  `CLAUDE.md` 开头列举 fork 独有路径的那句也补上了插件的三个位置。
- **版本号** `1.0.0`，与 CLI 无关（CLI 本身没有版本号）。
- **分支与安装**：插件随 CLI 放在 `feat/swift-bindings`。GitHub 默认分支 `master` 仍是收缩前的旧
  状态，没有 CLI，所以 README 的安装命令都钉了 ref：Claude Code 用
  `/plugin marketplace add MxIris-Reverse-Engineering/idax#feat/swift-bindings`，Codex 用
  `codex plugin marketplace add MxIris-Reverse-Engineering/idax --ref feat/swift-bindings`。
  清单的 `homepage` 同理指向该分支的 tree 页面，否则锚点 `#agent-plugin` 落在没有这一节的
  `master` README 上。
- **许可证**：仓库根目录没有 LICENSE 文件；README 的 License 一节与各 binding 自带的 LICENSE
  都是 MIT，清单据此写 `MIT`。
- **上游零侵入**：只新增文件，外加 fork 早已修改的 `README.md`（新内容紧跟在既有的 CLI 一节之后，
  fork 的 README 增量仍集中在一处）与 fork 独有的 `CLAUDE.md`。`.agents/plugins/marketplace.json`
  是上游 `.agents/` 目录下的新文件，不碰任何上游账本。

## 决策日志

| 日期 | 决定 | 理由 |
|------|------|------|
| 2026-10-05 | Created as Draft | 用户要求：idax 这类工具的 skill 放回各自仓库，以插件形式提供，不再在本机全局 skill 里维护 |
| 2026-10-05 | 插件放 `feat/swift-bindings`，安装命令钉 ref | CLI 只存在于这条分支；默认分支 `master` 是 fork 收缩前的旧状态 |
| 2026-10-05 | idalib 约束进 `CLAUDE.md`，不进插件 | 插件面向 CLI 的使用者；这些约束只对改 idax 的人有用，而 `CLAUDE.md` 在本仓库工作时会自动加载 |
| 2026-10-05 | 版本号 `1.0.0`，与 CLI 无关 | CLI 没有自己的版本号；改 skill 必须升版本，已装的插件才会更新 |
| 2026-10-05 | Implemented | 与插件同一提交落地。`claude plugin validate --strict`（marketplace、插件、skills 目录）与 Codex 的 `quick_validate.py` 均通过。不另写使用指南或实现说明：用法已有 `docs/Tools/IDAXCommandLine.md`，维护者要知道的约束写进了 `CLAUDE.md`；没有新术语 |
