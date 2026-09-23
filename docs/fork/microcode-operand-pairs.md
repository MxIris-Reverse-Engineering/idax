# 成对微码操作数的上游修复准备

2026-09-23，基于 `48b543e`，分支 `fix/microcode-operand-pairs`。
补丁通过独立工作分支交付，未合入 `feat/swift-bindings`，也未向上游发送。
长期 fork 的[零侵入约定](evolutions/draft-shrink-fork-to-cli.md)保持不变。

## 问题与证据

Swift decompiler 换用当前公开微码接口后，真实系统样本中的四个函数在
`parse_sdk_operand` 返回快照之前失败：`Unsupported register pair format`。
SDK 的 `mop_pair_t` 保存两个 `mop_t`，并未要求它们都是寄存器；现有解析器却只接受
`lop.t == mop_r && hop.t == mop_r`。

这个限制已存在于基线，并非 Swift 适配器新引入。历史追踪指向 `aa1c7221` 的严格检查；
旧独立微码导出器以默认寄存器编号继续处理其它成员，这也不能证明语义正确。
本轮检查上游 `src/decompiler.cpp` 历史和公开 issue，未找到已落地的同类修复。

永久回归用现有 ARM64 fixture，在 SDK `hxe_microcode` 回调中插入合法的常量/寄存器
成对操作数，再从公开 `generate_microcode` 读取。修复前测试进程退出 **1**，CTest
退出 **8**，精确复现上述错误。它没有直接调用私有解析函数，也不依赖巨大的系统数据库。

## 最终实现

- 在枚举末尾追加 `OperandPair = 17`，由拥有所有权的 `pair_low_operand` 和
  `pair_high_operand` 递归保存真实成员。
- 保持纯寄存器组合的 `RegisterPair` 和已有枚举值。空 SDK pair 显式报 Validation。
- 通用指令发射器递归重建 pair，验证两半齐全、宽度为正且总宽度一致，沿用嵌套深度限制。
- C transport 递归复制与释放，Swift 的 schema、生成值、输入编码和 native decoder
  同步；Rust、Node.js、Python 也同步输出映射。
- 没有扩大通用发射器支持的其它操作数种类；一个 pair 成员若本来是只读种类，重新发射
  仍返回原有 Unsupported 错误。

**必须把 native archive 与客户端一起重建。** `IdaxMicrocodeOperand` 增加两个指针，
结构体布局已经变化；保留原枚举数字只能保证枚举兼容，不能保证旧 archive 的二进制兼容。

## 验证

| 范围 | 本轮结果 |
|---|---|
| C++ 成对操作数、语义快照集成测试 | 2/2 通过，CTest 原始退出 0 |
| C++ pair 回归 | 值/宽度、快照销毁后的所有权、纯寄存器兼容、公开发射后读回、拒绝非法输入且不改块 |
| Swift runtime | 强制要求 Hex-Rays；混合 pair 往返及非法宽度/缺失成员检查通过，原始退出 0 |
| Swift 值生成器 `--check` | 314 个生成函数，0 个待手写转换 |
| Rust | `cargo check --package idax --all-targets` 通过 |
| Node.js | 修改后的 C++ translation unit 通过语法编译，TypeScript 声明检查通过，未运行 Node runtime |
| Python | 修改后的 C++ translation unit 通过语法编译，未运行 Python runtime；SDK 有弃用警告 |
| 下游 Swift adapter | 163 tests / 5 suites 通过，启用两套真实 IDA fixture，原始退出 0 |

本轮 native archive 以 macOS 14 编译，idax Swift runtime 测试程序按 package 的 macOS 13
目标链接，因此有部署版本提示。验证输入为 macOS 26.6.2 cache；没有验证 macOS 13 运行兼容。

旧系统数据库不在本机，用户授权用现有 `idax dyld-cache` 从本机 macOS 26.6.2 cache
创建 AppKit、SwiftUI、SwiftUICore 合库，创建进程退出 0。下游前后验证只打开新库及伴随
cache 的独立克隆，关闭时 `save: false`。最终微码导入和 Swift 主线渲染由 **16/20 → 20/20**，
进程退出 **0**；原成功函数 16/16 归一化后相同，Hex-Rays 原文 20/20 相同。
原库和三份克隆的 `.i64` SHA-256 一致，验证没有留下解包文件。完整输出证据见
swift-decompiler 的 `docs/explainers/185_microcode_operand_pairs.md` 和 `docs/PROGRESS.md`。

## 复跑

```bash
IDADIR='<ida-runtime>' cmake -S '<repo-root>' -B '<agent-build>' \
  -DIDAX_BUILD_TESTS=ON -DIDAX_BUILD_SWIFT=ON \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
queued-build cmake --build '<agent-build>'
queued-build ctest --test-dir '<agent-build>' --output-on-failure \
  -R '^(microcode_operand_pairs|decompiler_semantic_metadata)$'

python3 '<repo-root>/bindings/swift/scripts/generate_values.py' --check
IDAX_LIB_DIR='<agent-build>/bindings/swift' IDADIR='<ida-runtime>' \
  queued-build swift build --package-path '<repo-root>' --scratch-path '<agent-swift-build>' \
  --product IDAXRuntimeTests
IDAX_SWIFT_REQUIRE_DECOMPILER=1 IDADIR='<ida-runtime>' \
  queued-build '<agent-swift-build>/debug/IDAXRuntimeTests' \
  '<repo-root>/tests/fixtures/register_tracking_aarch64'
```

C++ 与 Swift runtime 入口都会先复制 fixture 到临时目录，不会保存回原 fixture。
原始日志由调用方保存在本轮 artifact 目录；测试成败只认原始退出码。

## 代码入口

- `include/ida/decompiler.hpp`、`src/decompiler.cpp`
- `bindings/rust/idax-sys/shim/idax_shim.h`、`idax_shim.cpp`
- `bindings/swift/value_schema.json`、`bridge/microcode.cpp`
- `bindings/swift/Sources/IDAX/Decompiler+MicrocodeValues.swift`
- `tests/integration/microcode_operand_pairs_test.cpp`
- `bindings/swift/Tests/Runtime/Microcode.swift`
