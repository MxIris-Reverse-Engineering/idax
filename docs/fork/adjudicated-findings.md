# 已裁决的 code-review 发现

判定为**误报**或**不值得修**的发现登记在此。之后每次 code-review 先对照本清单，已裁决且理由
仍成立的发现直接跳过，不再重走四问；若新证据推翻了当初的理由，更新本条目并重新裁决。

判定为**要修**的发现不进本清单——它们带着复现测试进代码库。

---

## F-001 ~ F-003：上游 Swift review 中在本 fork 仍成立的三条

**来源**：上游 `19h/idax` 的 `docs/reviews/pr-6-swift.md`，针对本 fork 的 PR head
`25b002a` 所做的独立复现。上游据此重写了 Swift bindings（commit `9a9036d`）。

**裁决日期**：2026-09-13
**裁决**：不修
**共同理由**：承载这三条缺陷的代码在提案[《收缩为上游之上的命令行工具》](evolutions/draft-shrink-fork-to-cli.md)
中被整体删除，改用上游的 Swift bindings。上游的对应实现中这三个问题均已不存在
（该 review 正是其重写动因）。为注定要删除的代码走完整的"写复现测试 → 变红 → 修复 →
留作回归测试"流程没有收益。

**共同的基线判定（四问之二）**：本 fork 的 `origin/master`（`b773382`）**不含**
`bindings/swift` 目录。这三条都不是基线上的旧问题，而是 `feat/swift-bindings` 分支引入的。

**共同的历史判定（四问之四）**：三处代码分别来自本分支的原始实现 commit
`56ece41`（Processor）与 `16a17a7`（Debugger），此后未被任何 commit 触及过同一问题。
不存在"当年修过又回归"的情况，也不存在有意为之的设计约束。

---

### F-001 处理器模块的可选回调不派发

**位置**：`bindings/swift/Sources/IDAX/Processor.swift:497-506`

**能复现吗（四问之一）**：能，真实存在。`ProcessorModule` 协议体（476 行起）只声明了
`info`、`analyze`、`emulate`、`outputInstruction`、`outputOperand` 五个必需成员。
`isCall`、`isReturn`、`mayBeFunction`、`isSaneInstruction`、`onNewFile`、`onOldFile`
这些可选回调**只存在于 protocol extension 的默认实现中**（497 行起）。

Swift 的协议扩展方法不参与动态派发：只有协议体内声明过的成员才走见证表（witness table）。
原生 trampoline 通过 `any ProcessorModule` 这个存在类型调用，因此实现方写的重写被完全绕过，
永远拿到扩展里的默认值（`isCall` 恒返回 0）。

触发路径：任何实现 `ProcessorModule` 并重写 `isCall` 的处理器模块，注册后由 IDA 询问
"这条指令是不是调用"时，得到的是默认值而非实现方的判断。

**影响范围（四问之三）**：对自定义处理器模块的使用者是高严重度——功能静默失效，没有任何
诊断。但本 fork 内没有任何调用方，`bindings/swift/Examples/` 与 `Tools/` 都不实现该协议。

**正确修法（供参考，本次不做）**：把这些可选成员的签名声明进协议体，默认实现留在扩展里。

---

### F-002 Appcall 执行器返回码反了

**位置**：`bindings/swift/Sources/IDAX/Debugger.swift:467`、`472`

**能复现吗（四问之一）**：能，真实存在，且是双向反转。

Swift trampoline 的约定：回调返回 nil（失败）时 `return 0`（467 行），回调返回有效结果
（成功）时 `return 1`（472 行）。

C 侧的约定相反——`bindings/rust/idax-sys/shim/idax_shim.cpp:9049`：

```cpp
int cb_rc = callback_(context_, &raw_req, &raw_result);
if (cb_rc != 0) {
    idax_debugger_appcall_result_free(&raw_result);
    return std::unexpected(ida::Error::sdk("appcall executor callback failed"));
}
```

非零即失败。于是：

- Swift 回调**成功**返回结果 → trampoline 返回 1 → C 侧判为失败，释放结果并报
  `appcall executor callback failed`。成功的调用永远拿不到返回值。
- Swift 回调**失败**返回 nil → trampoline 返回 0 → C 侧判为成功，继续读取
  `raw_result`，而该结构体在 443 行的 `guard` 之后从未被写入，是零值。失败被当成
  "成功返回 0"。

**影响范围（四问之三）**：对使用自定义 Appcall 执行器的调用方是高严重度——两个方向都错，
且失败方向会静默返回伪造的零值。本 fork 内无调用方。

---

### F-003 Appcall 回调对象泄漏

**位置**：`bindings/swift/Sources/IDAX/Debugger.swift:916`（注册）、`480`（清理）

**能复现吗（四问之一）**：能，真实存在。

注册时 `Unmanaged.passRetained(box).toOpaque()`（916 行）交出一份 +1 引用。该引用只在
**注册失败**的 catch 分支里被 release（930 行）。注册成功后：

- 清理 trampoline（480 行）用 `takeUnretainedValue` 取出 box 调用 `cleanup()`，**不释放**。
- C 侧 `~CAppcallExecutor`（`idax_shim.cpp:9012`）只调用 `cleanup_(context_)`，
  自身不持有也不释放该 Swift 引用。

因此注册成功的每一个执行器，其 `AppcallExecutorBox`（连同捕获的闭包及其捕获的一切）在进程
生命周期内永久驻留。反复注册/注销会线性累积。

**影响范围（四问之三）**：中等。单次泄漏量取决于闭包捕获了什么；对长期运行的插件宿主中
反复注册执行器的场景会累积。本 fork 内无调用方。

**正确修法（供参考，本次不做）**：所有权归原生可调用对象一次持有——清理 trampoline 用
`takeRetainedValue`，或在其中显式 `release()`，并覆盖注册失败、自注销、在途派发三条路径。

---

## 横向排查结论

按项目规则，确认为真的问题必须在整个代码库搜索同一模式的其它实例。

- **F-001 的模式**（可选回调只写在协议扩展里）：`bindings/swift/Sources/IDAX/` 下另有
  `LoaderModule`、`PluginModule` 两个同类协议。收缩后这些文件整体删除，未逐一排查——
  本条记录该排查**因代码删除而未进行**，若将来从归档标签
  `archive/parallel-swift-bindings-20260913` 中恢复任何一处，需先补做。
- **F-002 / F-003 的模式**（trampoline 返回码约定、`Unmanaged` 所有权）：`Debugger.swift`
  中另有十余处 `passRetained` / `takeUnretainedValue` 配对（987、1006、1025、1044、1063、
  1082、1101、1120 行等）。同样因整体删除未逐一核对，同上。
