# Fork 专属文档

本仓库是 [`19h/idax`](https://github.com/19h/idax) 的 fork。`docs/` 下除本目录外的所有内容
都跟踪上游、按字节对齐，**不得在此编辑**；`docs/fork/` 是上游永远不会存在的路径，因此本目录
下的文件在每次同步时零冲突。

## 与上游记录体系的分工

| 位置 | 归属 | 可否在本仓库编辑 |
|---|---|---|
| `agents.md`、`.agents/*.md` | 上游的路线图、发现、决策、进度 | 否——仅当改动确实属于上游时 |
| `.agents/fork/*.md` | fork 对上述七份账本的镜像 | 见下方「停用计划」 |
| `docs/fork/` | fork 特有的演进提案与裁决记录 | 是 |

## 停用计划

提案[《收缩为上游之上的命令行工具》](evolutions/draft-shrink-fork-to-cli.md)决定停用
`.agents/fork/` 下的七份镜像账本：收缩后 fork 相对上游的增量只剩 `idax` 命令行工具与两块
C++ 补丁，维护七份账本的写入成本远超收益。

该提案已于 2026-09-13 批准（状态 `Accepted`），实施进行中。`.agents/fork/` 的冻结时点会在
收缩完成时登记于此。

## 目录

- [evolutions/](evolutions/) —— fork 演进提案，含索引与项目类型声明
- [adjudicated-findings.md](adjudicated-findings.md) —— code-review 中判定为误报或不值得修的
  发现及其理由。每次 review 前先对照，已裁决且理由仍成立的直接跳过
