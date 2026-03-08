# Swift Bindings Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix memory safety bugs, improve type safety, and harden the existing Swift bindings.

**Architecture:** The Swift bindings have a two-layer design: `CIDA` (C shim) → `IDA` (Swift wrapper). All fixes target the `IDA` Swift wrapper layer. The C shim is shared with Rust bindings and remains unchanged.

**Tech Stack:** Swift 6.0, Swift Testing framework, SPM

---

## Task 1: Fix systemic double-free in `takeCString` + `defer { _free }` pattern

**Problem:** Every `init(raw:)` method calls `takeCString()` which frees malloc'd strings via `idax_free_string()`. Then `defer { _free(&raw) }` in the calling function frees the same pointers again via the struct's free function. This is undefined behavior.

**Affected files (6):**
- `Sources/IDA/Segment.swift:122-123` — `takeCString(raw.name)`, `takeCString(raw.class_name)`
- `Sources/IDA/Function.swift:146` — `takeCString(raw.name)`
- `Sources/IDA/Function.swift:109,112` — `takeCString(v.name)`, `takeCString(v.comment)` in `frame(at:)`
- `Sources/IDA/Entry.swift:22-23` — `takeCString(raw.name)`, `takeCString(raw.forwarder)`
- `Sources/IDA/Instruction.swift:103,113` — `takeCString(raw.mnemonic)`, `takeCString(o.register_name)`
- `Sources/IDA/Decompiler.swift:69-75` — `takeCString(v.name)`, `takeCString(v.type_name)`, `takeCString(v.comment)`

**Files:**
- Modify: `bindings/swift/Sources/IDA/Error.swift` (add helper)
- Modify: `bindings/swift/Sources/IDA/Segment.swift`
- Modify: `bindings/swift/Sources/IDA/Function.swift`
- Modify: `bindings/swift/Sources/IDA/Entry.swift`
- Modify: `bindings/swift/Sources/IDA/Instruction.swift`
- Modify: `bindings/swift/Sources/IDA/Decompiler.swift`

**Step 1: Add `borrowCString` helper to `Error.swift`**

Add below `takeCString`:

```swift
/// Read a C string without freeing it. Used when a separate `_free` function
/// owns the lifecycle of the containing struct.
func borrowCString(_ ptr: UnsafePointer<CChar>?) -> String {
    guard let ptr else { return "" }
    return String(cString: ptr)
}
```

**Step 2: Replace `takeCString` with `borrowCString` in all `init(raw:)` methods**

In `Segment.swift` init(raw:), change:
```swift
self.name = borrowCString(raw.name)
self.className = borrowCString(raw.class_name)
```

In `Function.swift` init(raw:), change:
```swift
self.name = borrowCString(raw.name)
```

In `Function.swift` frame(at:), change:
```swift
name: borrowCString(v.name),
...
comment: borrowCString(v.comment),
```

In `Entry.swift` byIndex(_:), change:
```swift
name: borrowCString(raw.name),
forwarder: borrowCString(raw.forwarder)
```

In `Instruction.swift` init(raw:), change:
```swift
self.mnemonic = borrowCString(raw.mnemonic)
...
registerName: borrowCString(o.register_name),
```

In `Decompiler.swift` variables getter, change:
```swift
name: borrowCString(v.name),
typeName: borrowCString(v.type_name),
...
comment: borrowCString(v.comment)
```

**Step 3: Build to verify**

Run: `cd /Volumes/Repositories/Private/Fork/Library/idax/bindings/swift && swift build 2>&1 | head -20`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add bindings/swift/Sources/IDA/Error.swift bindings/swift/Sources/IDA/Segment.swift \
  bindings/swift/Sources/IDA/Function.swift bindings/swift/Sources/IDA/Entry.swift \
  bindings/swift/Sources/IDA/Instruction.swift bindings/swift/Sources/IDA/Decompiler.swift
git commit -m "fix: resolve systemic double-free in Swift bindings init(raw:) methods

takeCString() freed malloc'd strings, then defer { _free(&raw) } freed
them again. Replace with borrowCString() in all init(raw:) paths so the
struct's _free function is the sole owner of cleanup."
```

---

## Task 2: Fix Event.swift callback box memory leak

**Problem:** `Unmanaged.passRetained(box)` retains the callback box, but `EventSubscription.deinit`/`cancel()` only call `idax_event_unsubscribe(token)` without releasing the box. The box object leaks permanently.

**Files:**
- Modify: `bindings/swift/Sources/IDA/Event.swift`

**Step 1: Store context pointer in `EventSubscription` and release on cleanup**

Replace the `EventSubscription` class:

```swift
public final class EventSubscription: @unchecked Sendable {
    private let token: UInt64
    private let context: UnsafeMutableRawPointer
    private var active = true

    init(token: UInt64, context: UnsafeMutableRawPointer) {
        self.token = token
        self.context = context
    }

    deinit {
        if active {
            idax_event_unsubscribe(token)
            Unmanaged<AnyObject>.fromOpaque(context).release()
        }
    }

    public func cancel() {
        if active {
            idax_event_unsubscribe(token)
            Unmanaged<AnyObject>.fromOpaque(context).release()
            active = false
        }
    }
}
```

**Step 2: Pass context to EventSubscription in all `on*` methods**

Each subscription factory method must pass `ctx` to the subscription. For example, `onRenamed`:

```swift
public static func onRenamed(
    _ handler: @escaping (Address, String, String) -> Void
) throws(IDAError) -> EventSubscription {
    let box = RenamedBox(handler: handler)
    let ctx = Unmanaged.passRetained(box).toOpaque()
    var token: UInt64 = 0
    do {
        try checkStatus(
            idax_event_on_renamed(renamedTrampoline, ctx, &token),
            "event.onRenamed"
        )
    } catch {
        Unmanaged<AnyObject>.fromOpaque(ctx).release()
        throw error
    }
    return EventSubscription(token: token, context: ctx)
}
```

Apply the same pattern to `onFunctionAdded`, `onFunctionDeleted`, `onBytePatched` — each must:
1. Wrap the `checkStatus` call in `do/catch`
2. Release `ctx` on failure
3. Pass `ctx` to `EventSubscription`

**Step 3: Build to verify**

Run: `cd /Volumes/Repositories/Private/Fork/Library/idax/bindings/swift && swift build 2>&1 | head -20`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add bindings/swift/Sources/IDA/Event.swift
git commit -m "fix: resolve callback box memory leak in Event.swift

EventSubscription now stores the Unmanaged context pointer and releases
it on cancel/deinit. Also releases on subscription failure to prevent
leaks in error paths."
```

---

## Task 3: Fix force unwraps — replace `handle!` / `out!` with `guard let`

**Problem:** Several places force-unwrap optional handles returned by C shim. If the shim returns 0 (success) but the output pointer is nil, the app crashes instead of throwing a descriptive error.

**Affected locations:**
- `Decompiler.swift:106` — `DecompiledFunction(handle!)`
- `Types.swift:78` — `TypeHandle(out!)`
- `Types.swift:95` — `TypeHandle(out!)`
- `Types.swift:101` — `TypeHandle(out!)`
- `Types.swift:115` — `TypeHandle(out!)`
- `Storage.swift:23` — `StorageNode(handle!)`
- `Storage.swift:29` — `StorageNode(handle!)`

**Files:**
- Modify: `bindings/swift/Sources/IDA/Decompiler.swift`
- Modify: `bindings/swift/Sources/IDA/Types.swift`
- Modify: `bindings/swift/Sources/IDA/Storage.swift`

**Step 1: Replace each force unwrap with guard let + throw**

Pattern — replace:
```swift
return TypeHandle(out!)
```
with:
```swift
guard let out else {
    throw IDAError(category: .internal, code: 0, message: "nil handle after successful call")
}
return TypeHandle(out)
```

Apply to all 7 locations listed above.

**Step 2: Build to verify**

Run: `cd /Volumes/Repositories/Private/Fork/Library/idax/bindings/swift && swift build 2>&1 | head -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add bindings/swift/Sources/IDA/Decompiler.swift bindings/swift/Sources/IDA/Types.swift \
  bindings/swift/Sources/IDA/Storage.swift
git commit -m "fix: replace force unwraps with guard let + throw in handle construction"
```

---

## Task 4: Add type-safe enums for raw Int32 fields

**Problem:** Several struct fields and function parameters use raw `Int32` where a typed enum would be safer and more discoverable.

**Files:**
- Modify: `bindings/swift/Sources/IDA/Xref.swift`
- Modify: `bindings/swift/Sources/IDA/Fixup.swift`
- Modify: `bindings/swift/Sources/IDA/Name.swift`
- Modify: `bindings/swift/Sources/IDA/Decompiler.swift`
- Modify: `bindings/swift/Sources/IDA/Instruction.swift`

**Step 1: Add `ReferenceType` enum and update `Xref.swift`**

Add at top of `Xref.swift`:
```swift
/// Cross-reference type classification.
public enum ReferenceType: Int32, Sendable {
    case unknown = 0
    case call = 1, jump = 2, ordinaryFlow = 3
    case dataRead = 4, dataWrite = 5, dataOffset = 6
}
```

Change `CrossReference.type` from `Int32` to `ReferenceType`:
```swift
public struct CrossReference: Sendable {
    public let from: Address
    public let to: Address
    public let isCode: Bool
    public let type: ReferenceType
    public let isUserDefined: Bool
}
```

Update `xrefArray` mapping:
```swift
type: ReferenceType(rawValue: r.type) ?? .unknown,
```

Update `addCode`/`addData` parameter types:
```swift
public static func addCode(from: Address, to: Address, type: ReferenceType = .unknown) throws(IDAError) {
    try checkStatus(idax_xref_add_code(from, to, type.rawValue), "xref.addCode")
}

public static func addData(from: Address, to: Address, type: ReferenceType = .unknown) throws(IDAError) {
    try checkStatus(idax_xref_add_data(from, to, type.rawValue), "xref.addData")
}
```

**Step 2: Add `FixupType` enum and update `Fixup.swift`**

Add at top of `Fixup.swift`:
```swift
/// Fixup (relocation) type classification.
public enum FixupType: Int32, Sendable {
    case unknown = 0
    case byte = 1, word = 2, dword = 3, qword = 4
    case offset16 = 5, offset32 = 6, offset64 = 7
    case low8 = 8, low16 = 9, high8 = 10, high16 = 11
    case custom = 0x4000
}
```

Change `Fixup.type` from `Int32` to `FixupType`:
```swift
public let type: FixupType
```

Update init:
```swift
self.type = FixupType(rawValue: raw.type) ?? .unknown
```

**Step 3: Add `DemangledForm` enum and update `Name.swift`**

Add at top of `Name.swift`:
```swift
/// Demangling output form.
public enum DemangledForm: Int32, Sendable {
    case short = 0
    case long = 1
    case typeOnly = 2
}
```

Change `demangled`:
```swift
public static func demangled(at address: Address, form: DemangledForm = .short) throws(IDAError) -> String {
    try withStringOutput("name.demangled") { idax_name_demangled(address, form.rawValue, $0) }
}
```

**Step 4: Add `VariableStorage` enum and update `Decompiler.swift`**

Add before `LocalVariable`:
```swift
/// Storage class for a decompiler local variable.
public enum VariableStorage: Int, Sendable {
    case unknown = 0
    case register = 1
    case stack = 2
}
```

Change `LocalVariable.storage` from `Int` to `VariableStorage`:
```swift
public let storage: VariableStorage
```

Update the mapping in `variables` getter:
```swift
storage: VariableStorage(rawValue: Int(v.storage)) ?? .unknown,
```

**Step 5: Add `RegisterCategory` and update `Instruction.swift`**

Add to `Operand` struct:
```swift
public let registerCategory: Int32
```

Update `Operand` init in `Instruction.init(raw:)`:
```swift
registerCategory: o.register_category,
```

**Step 6: Build to verify**

Run: `cd /Volumes/Repositories/Private/Fork/Library/idax/bindings/swift && swift build 2>&1 | head -20`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add bindings/swift/Sources/IDA/Xref.swift bindings/swift/Sources/IDA/Fixup.swift \
  bindings/swift/Sources/IDA/Name.swift bindings/swift/Sources/IDA/Decompiler.swift \
  bindings/swift/Sources/IDA/Instruction.swift
git commit -m "feat: add type-safe enums for ReferenceType, FixupType, DemangledForm, VariableStorage

Replace raw Int32 fields with typed enums for better discoverability
and compile-time safety."
```

---

## Task 5: Clean up Package.swift

**Problem:** `CIDA` is exposed as a public product (users could bypass the safe layer). It should be internal only.

**Files:**
- Modify: `bindings/swift/Package.swift`

**Step 1: Remove CIDA from products**

Change:
```swift
products: [
    .library(name: "IDA", targets: ["IDA"]),
    .library(name: "CIDA", targets: ["CIDA"]),
],
```
to:
```swift
products: [
    .library(name: "IDA", targets: ["IDA"]),
],
```

**Step 2: Build to verify**

Run: `cd /Volumes/Repositories/Private/Fork/Library/idax/bindings/swift && swift build 2>&1 | head -20`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add bindings/swift/Package.swift
git commit -m "chore: remove CIDA from public products in Package.swift"
```

---

## Task 6: Expand unit test coverage

**Problem:** Only 4 enum rawValue tests exist. All value types, error helpers, and struct constructions are untested.

**Files:**
- Modify: `bindings/swift/Tests/IDATests/UnitTests.swift`

**Step 1: Add comprehensive enum coverage tests**

```swift
@Suite("IDA SegmentType — full coverage")
struct SegmentTypeFullTests {
    @Test func allRawValues() {
        #expect(SegmentType.normal.rawValue == 0)
        #expect(SegmentType.external.rawValue == 1)
        #expect(SegmentType.code.rawValue == 2)
        #expect(SegmentType.data.rawValue == 3)
        #expect(SegmentType.bss.rawValue == 4)
        #expect(SegmentType.absoluteSymbols.rawValue == 5)
        #expect(SegmentType.common.rawValue == 6)
        #expect(SegmentType.null.rawValue == 7)
        #expect(SegmentType.undefined.rawValue == 8)
        #expect(SegmentType.import.rawValue == 9)
        #expect(SegmentType.internalMemory.rawValue == 10)
        #expect(SegmentType.group.rawValue == 11)
    }

    @Test func unknownRawValueReturnsNil() {
        #expect(SegmentType(rawValue: 99) == nil)
    }
}

@Suite("IDA OperandType — full coverage")
struct OperandTypeFullTests {
    @Test func allRawValues() {
        #expect(OperandType.void_.rawValue == 0)
        #expect(OperandType.register.rawValue == 1)
        #expect(OperandType.memory.rawValue == 2)
        #expect(OperandType.phrase.rawValue == 3)
        #expect(OperandType.displacement.rawValue == 4)
        #expect(OperandType.immediate.rawValue == 5)
        #expect(OperandType.far.rawValue == 6)
        #expect(OperandType.near.rawValue == 7)
    }
}
```

**Step 2: Add new enum tests for Task 4 additions**

```swift
@Suite("IDA ReferenceType")
struct ReferenceTypeTests {
    @Test func rawValues() {
        #expect(ReferenceType.unknown.rawValue == 0)
        #expect(ReferenceType.call.rawValue == 1)
        #expect(ReferenceType.jump.rawValue == 2)
        #expect(ReferenceType.ordinaryFlow.rawValue == 3)
        #expect(ReferenceType.dataRead.rawValue == 4)
        #expect(ReferenceType.dataWrite.rawValue == 5)
        #expect(ReferenceType.dataOffset.rawValue == 6)
    }

    @Test func unknownRawValueReturnsNil() {
        #expect(ReferenceType(rawValue: 99) == nil)
    }
}

@Suite("IDA FixupType")
struct FixupTypeTests {
    @Test func basicRawValues() {
        #expect(FixupType.unknown.rawValue == 0)
        #expect(FixupType.byte.rawValue == 1)
        #expect(FixupType.word.rawValue == 2)
        #expect(FixupType.dword.rawValue == 3)
        #expect(FixupType.qword.rawValue == 4)
        #expect(FixupType.custom.rawValue == 0x4000)
    }
}

@Suite("IDA DemangledForm")
struct DemangledFormTests {
    @Test func rawValues() {
        #expect(DemangledForm.short.rawValue == 0)
        #expect(DemangledForm.long.rawValue == 1)
        #expect(DemangledForm.typeOnly.rawValue == 2)
    }
}

@Suite("IDA VariableStorage")
struct VariableStorageTests {
    @Test func rawValues() {
        #expect(VariableStorage.unknown.rawValue == 0)
        #expect(VariableStorage.register.rawValue == 1)
        #expect(VariableStorage.stack.rawValue == 2)
    }
}
```

**Step 3: Add IDAError model tests**

```swift
@Suite("IDA Error Helpers")
struct ErrorHelperTests {
    @Test func consumeLastErrorUseFallbackWhenNoCategorySet() {
        // When no C shim error is set, category defaults to 0 which maps to nil,
        // so consumeLastError should use .internal as fallback
        let err = consumeLastError(fallback: "test fallback")
        #expect(err.category == .internal)
    }

    @Test func checkStatusSuccessDoesNotThrow() throws {
        // 0 = success
        try checkStatus(0, "should not throw")
    }

    @Test func checkStatusFailureThrows() {
        #expect(throws: IDAError.self) {
            try checkStatus(-1, "expected failure")
        }
    }
}
```

**Step 4: Add value type construction tests**

```swift
@Suite("IDA Permissions")
struct PermissionsTests {
    @Test func defaultValuesAreFalse() {
        let p = Permissions(read: false, write: false, execute: false)
        #expect(!p.read)
        #expect(!p.write)
        #expect(!p.execute)
    }

    @Test func allTrue() {
        let p = Permissions(read: true, write: true, execute: true)
        #expect(p.read)
        #expect(p.write)
        #expect(p.execute)
    }
}

@Suite("IDA Chunk")
struct ChunkTests {
    @Test func basicConstruction() {
        let c = Chunk(start: 0x1000, end: 0x2000, isTail: false, owner: 0x1000)
        #expect(c.start == 0x1000)
        #expect(c.end == 0x2000)
        #expect(!c.isTail)
    }
}

@Suite("IDA Operand predicates")
struct OperandPredicateTests {
    @Test func isImmediateWhenTypeIsImmediate() {
        let op = Operand(
            index: 0, operandType: .immediate, registerID: 0,
            registerName: "", value: 42, targetAddress: 0,
            byteWidth: 4, registerCategory: 0
        )
        #expect(op.isImmediate)
        #expect(!op.isRegister)
        #expect(!op.isMemory)
    }

    @Test func isRegisterWhenTypeIsRegister() {
        let op = Operand(
            index: 0, operandType: .register, registerID: 1,
            registerName: "rax", value: 0, targetAddress: 0,
            byteWidth: 8, registerCategory: 0
        )
        #expect(op.isRegister)
        #expect(!op.isImmediate)
    }
}
```

**Step 5: Remove now-redundant old test suites**

Delete the old `SegmentTypeTests` and `OperandTypeTests` suites since the new full-coverage suites replace them.

**Step 6: Run tests**

Run: `cd /Volumes/Repositories/Private/Fork/Library/idax/bindings/swift && swift test 2>&1 | tail -30`
Expected: All tests pass

**Step 7: Commit**

```bash
git add bindings/swift/Tests/IDATests/UnitTests.swift
git commit -m "test: expand Swift binding unit tests

Add full enum coverage for SegmentType, OperandType, ReferenceType,
FixupType, DemangledForm, VariableStorage. Add error helper tests,
value type construction tests, and Operand predicate tests."
```

---

## Summary

| Task | Type | Risk | Description |
|------|------|------|-------------|
| 1 | Bug fix | **Critical** | Double-free in all `init(raw:)` + `defer { _free }` paths |
| 2 | Bug fix | **High** | Callback box memory leak in Event.swift |
| 3 | Bug fix | **Medium** | Force unwraps → guard let + throw |
| 4 | Enhancement | Low | Type-safe enums for raw Int32 fields |
| 5 | Cleanup | Low | Remove CIDA from public products |
| 6 | Testing | Low | Expand unit test coverage |
