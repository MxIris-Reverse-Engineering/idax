<!-- Fork-local records. See .agents/fork/README.md. -->

# Roadmap (fork)

Entries this fork added to `.agents/roadmap.md`, moved here so that file can track
upstream byte for byte. Numbering is whatever it was before the move; it is
independent of upstream's, which is exactly why these live in a separate file
— upstream's Phase 23 is an ida-trida port, ours was the Swift dyld cache
tool, and both had claimed `P23.1`.

---

- Fork Phase S1 (was numbered "Phase 23" before the move): 100%（Swift dyld shared cache database 命令行工具、显式输出路径保存、binding parity、测试、打包、安装、IDA 9.4 DSC service adaptation 与文档均已完成）
### Fork Phase S1 — Swift Dyld Cache Database Creator (entries below were numbered P23.x)
- [x] P23.1 Add explicit output-path database saving to the C++ API, central C ABI, and Swift/Node/Rust bindings.
- [x] P23.2 Add a `swift-argument-parser` executable that loads one or more requested dyld shared cache images plus optional header, branch-island, branch-mapping, global-offset-table, and gap regions.
- [x] P23.3 Add deterministic output naming, overwrite protection, argument validation, and focused unit coverage.
- [x] P23.4 Rebuild the committed `CIDAX.xcframework` and validate the command against a real dyld shared cache fixture.
- [x] P23.5 同步公开文档与分布式 `.agents/` protocol 记录。
- [x] P23.6 将旧 `--image` 替换为支持列表输入的 `--image-name` / `--image-path`，并新增 database 打开前的 cache image name resolution。
- [x] P23.7 新增当前用户安装脚本，将 release executable 与 `CIDAX.framework` 一并部署，并提供 `PATH` 内可直接调用的 launcher。
- [x] P23.8 适配 IDA 9.4 public `dscu_svc_t`、新增 cache-data region loading、保留 IDA 9.3 source compatibility，并重建验证 9.4 `CIDAX.xcframework`。
## Upstream Relationship
- [x] U1 Establish shared ancestry with `19h/idax` by replaying post-February work onto the matching upstream commit, then merge normally.
- [x] U2 Verify the merge across every layer: 42/42 CTest including all integration suites, Rust 173, Node 277, Swift 64, plus a clean-clone build.
- [x] U3 Offer the Swift bindings upstream as a draft pull request with the two domains they depend on.
- [ ] U4 Respond to upstream review; mirror any restructuring back onto the merge branch before publishing it.
- [ ] U5 Publish the merge branch (force-push, since 87 commits were replayed onto a new base — verify with `git cherry` first).

## Runtime Correctness

- [x] F4 Populate stack offsets in `ida::microcode::snapshot`, add a runtime regression test, rebuild the Swift development archives, and verify the downstream Swift decompiler adapter.

## Swift Parity Completion (plan: `docs/plans/2026-08-27-swift-parity-completion.md`)

- [x] F5 Batch 1a — adopt module-wide `MainActor` isolation across the Swift bindings, put the callback contract in the type system, and bring the CLI tool along.
- [ ] F6 Batch 1b — add the five zero-coverage domains (bookmark, problem, undo, navigation, FilePath) plus the visible-skip integration test scaffold.
- [ ] F7 Rebuild the packaged `CIDAX.xcframework`, which has lagged the C ABI since `80b6e63` and leaves consumer mode unable to reach 281 symbols.
