# Swift Bindings Completeness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all API gaps between the C++ library and Swift bindings — typed enums, convenience functions, bug fixes, C shim extensions for decompiler/microcode/processor/database.

**Architecture:** Incremental 5-step approach. Step 1 is pure Swift (no C shim changes). Steps 2–5 extend both the C shim (.h × 2 + .cpp) and Swift wrappers. Each step is independently compilable and testable.

**Tech Stack:** Swift 6.2, C23, C++23, SPM, Swift Testing framework

**Spec:** `docs/superpowers/specs/2026-03-31-swift-bindings-completeness-design.md`

---

## File Structure

### Step 1 — Pure Swift modifications
| Action | Path |
|--------|------|
| Modify | `bindings/swift/Sources/IDAX/Types.swift` — add `CallingConvention` enum, update `functionType`/`callingConvention` |
| Modify | `bindings/swift/Sources/IDAX/Lines.swift` — add `Color` enum, update `colorString` |
| Modify | `bindings/swift/Sources/IDAX/Database.swift` — add `ProcessorID` enum, `addressBounds`, `processor` |
| Modify | `bindings/swift/Sources/IDAX/Graph.swift` — fix `GraphLayout` to match C++ values |
| Modify | `bindings/swift/Sources/IDAX/Segment.swift` — add `first`/`last` properties |
| Modify | `bindings/swift/Sources/IDAX/Diagnostics.swift` — add `enrich`/`assertInvariant` |
| Modify | `bindings/swift/Sources/IDAX/Xref.swift` — add filter predicates on `CrossReference` |
| Modify | `bindings/swift/Sources/IDAX/Decompiler.swift` — add `DecompilerView` struct |
| Modify | `bindings/swift/Sources/IDAX/Data.swift` — fix `writeTyped` for string/bytes/array |
| Modify | `bindings/swift/Sources/IDAX/UI.swift` — rename `widgetId` → `widgetID` |
| Modify | `bindings/swift/Tests/IDAXTests/UnitTests.swift` — fix hardcoded path + add new tests |

### Steps 2–5 — C shim + Swift
| Action | Path |
|--------|------|
| Modify | `bindings/swift/Sources/CIDAX/include/idax_shim.h` — add new declarations |
| Modify | `bindings/rust/idax-sys/shim/idax_shim.h` — keep in sync |
| Modify | `bindings/rust/idax-sys/shim/idax_shim.cpp` — add implementations |
| Modify | `bindings/swift/Sources/IDAX/Decompiler.swift` — Steps 2–3 additions |
| Create | `bindings/swift/Sources/IDAX/Processor.swift` — Step 4 |
| Modify | `bindings/swift/Sources/IDAX/Database.swift` — Step 5 additions |

---

## Step 1: Pure Swift Enums + Convenience Functions + Bug Fixes

### Task 1: Add `CallingConvention` enum to Types.swift

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Types.swift`

**Important:** C++ enum values (from `include/ida/type.hpp`): Unknown=0, Cdecl=1, Stdcall=2, Pascal=3, Fastcall=4, Thiscall=5, Swift=6, Golang=7, UserDefined=8.

- [ ] **Step 1: Add the enum definition**

Insert before the `TypeHandle` struct (before line 32):

```swift
/// Calling convention for function types.
///
/// Mirrors C++ `ida::type::CallingConvention`.
public enum CallingConvention: Int32, Sendable {
    case unknown = 0
    case cdecl = 1
    case stdcall = 2
    case pascal = 3
    case fastcall = 4
    case thiscall = 5
    case swift = 6
    case golang = 7
    case userDefined = 8
}
```

- [ ] **Step 2: Update `functionType` to use the enum**

In `Types.swift` around line 150, change the parameter from `callingConvention: Int = 0` to `callingConvention: CallingConvention = .unknown`:

```swift
    public static func functionType(
        returnType: borrowing TypeHandle,
        callingConvention: CallingConvention = .unknown,
        hasVarargs: Bool = false,
        arguments: (inout FunctionTypeArguments) -> Void
    ) throws(IDAError) -> TypeHandle {
```

And update the call site inside the function body, change `Int32(callingConvention)` to `callingConvention.rawValue`:

```swift
            idax_type_function_type(
                returnType.handle,
                buf.baseAddress,
                buf.count,
                callingConvention.rawValue,
                hasVarargs ? 1 : 0,
                &out
            )
```

- [ ] **Step 3: Update `callingConvention` property to return the enum**

Around line 222, change from `Int` to `CallingConvention`:

```swift
    public var callingConvention: CallingConvention {
        get throws(IDAError) {
            var out: Int32 = 0
            try checkStatus(idax_type_calling_convention(handle, &out), "type.callingConvention")
            guard let convention = CallingConvention(rawValue: out) else {
                throw IDAError(category: .unsupported, code: out,
                               message: "unknown calling convention: \(out)")
            }
            return convention
        }
    }
```

- [ ] **Step 4: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`
Expected: BUILD SUCCEEDED (or only warnings about unrelated things)

- [ ] **Step 5: Commit**

```bash
git add bindings/swift/Sources/IDAX/Types.swift
git commit -m "feat(swift): add CallingConvention enum, replace raw Int"
```

---

### Task 2: Add `Color` enum to Lines.swift

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Lines.swift`

**Important:** C++ enum values (from `include/ida/lines.hpp`): Default=0x01 through Collapsed=0x27. Constants: kColorOn='\x01', kColorOff='\x02', kColorEsc='\x03', kColorInv='\x04', kColorAddr=0x28, kColorAddrSize=16.

- [ ] **Step 1: Add the Color enum and constants**

Insert after the `internal import CIDAX` line (line 1), before the `Lines` enum:

```swift
/// Color tag identifiers for IDA listing output.
///
/// Mirrors C++ `ida::lines::Color`.
public enum Color: UInt8, Sendable {
    case `default` = 0x01
    case regularComment = 0x02
    case repeatableComment = 0x03
    case autoComment = 0x04
    case instruction = 0x05
    case dataName = 0x06
    case regularDataName = 0x07
    case demangledName = 0x08
    case symbol = 0x09
    case charLiteral = 0x0A
    case string = 0x0B
    case number = 0x0C
    case void_ = 0x0D
    case codeReference = 0x0E
    case dataReference = 0x0F
    case codeReferenceTail = 0x10
    case dataReferenceTail = 0x11
    case error = 0x12
    case prefix = 0x13
    case binaryPrefix = 0x14
    case extra = 0x15
    case altOperand = 0x16
    case hiddenName = 0x17
    case libraryName = 0x18
    case localName = 0x19
    case dummyCodeName = 0x1A
    case asmDirective = 0x1B
    case macro = 0x1C
    case dataString = 0x1D
    case dataChar = 0x1E
    case dataNumber = 0x1F
    case keyword = 0x20
    case register = 0x21
    case importedName = 0x22
    case segmentName = 0x23
    case unknownName = 0x24
    case codeName = 0x25
    case userName = 0x26
    case collapsed = 0x27

    /// Tag byte that turns a color ON in tagged text.
    public static let tagOn: UInt8 = 0x01
    /// Tag byte that turns a color OFF in tagged text.
    public static let tagOff: UInt8 = 0x02
    /// Escape byte for embedding tag bytes as literals.
    public static let tagEscape: UInt8 = 0x03
    /// Inverse color toggle byte.
    public static let tagInverse: UInt8 = 0x04
    /// Start value for embedded address tags.
    public static let addressTag: UInt8 = 0x28
    /// Byte length of an embedded address tag.
    public static let addressTagSize: Int = 16
}
```

- [ ] **Step 2: Update `colorString` to take `Color` instead of `UInt8`**

Change the existing function signature:

```swift
    public static func colorString(_ text: String, color: Color) throws(IDAError) -> String {
        try withStringOutput("lines.colstr") { out in
            text.withCString { idax_lines_colstr($0, color.rawValue, out) }
        }
    }
```

- [ ] **Step 3: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add bindings/swift/Sources/IDAX/Lines.swift
git commit -m "feat(swift): add Color enum with 39 cases and tag constants"
```

---

### Task 3: Add `ProcessorID` enum and Database convenience properties

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Database.swift`

**Important:** C++ enum values from `include/ida/database.hpp` — `ProcessorId` has 78 cases (0–77) with explicit values.

- [ ] **Step 1: Add the ProcessorID enum**

Insert near the top of `Database.swift`, after the imports and before the `Database` enum:

```swift
/// Processor module identifier.
///
/// Mirrors C++ `ida::database::ProcessorId`.
public enum ProcessorID: Int32, Sendable {
    case intelX86 = 0
    case z80 = 1
    case intelI860 = 2
    case intel8051 = 3
    case tms320c5x = 4
    case mos6502 = 5
    case pdp11 = 6
    case motorola68k = 7
    case javaVM = 8
    case motorola6800 = 9
    case st7 = 10
    case motorola68hc12 = 11
    case mips = 12
    case arm = 13
    case tms320c6x = 14
    case powerPC = 15
    case intel80196 = 16
    case z8 = 17
    case superH = 18
    case dotNet = 19
    case avr = 20
    case h8 = 21
    case pic = 22
    case sparc = 23
    case alpha = 24
    case hppa = 25
    case h8500 = 26
    case triCore = 27
    case dsp56k = 28
    case c166 = 29
    case st20 = 30
    case ia64 = 31
    case intelI960 = 32
    case f2mc16 = 33
    case tms320c54x = 34
    case tms320c55x = 35
    case trimedia = 36
    case m32r = 37
    case nec78k0 = 38
    case nec78k0s = 39
    case mitsubishiM740 = 40
    case mitsubishiM7700 = 41
    case st9 = 42
    case fujitsuFR = 43
    case motorola68hc16 = 44
    case mitsubishiM7900 = 45
    case tms320c3 = 46
    case kr1878 = 47
    case adsp218x = 48
    case oakDSP = 49
    case tlcs900 = 50
    case rockwellC39 = 51
    case cr16 = 52
    case mn10200 = 53
    case tms320c1x = 54
    case necV850x = 55
    case scriptAdapter = 56
    case efiBytecode = 57
    case msp430 = 58
    case spu = 59
    case dalvik = 60
    case wdc65c816 = 61
    case m16c = 62
    case arc = 63
    case unsp = 64
    case tms320c28x = 65
    case dsp96000 = 66
    case spc700 = 67
    case adsp2106x = 68
    case pic16 = 69
    case s390 = 70
    case xtensa = 71
    case riscV = 72
    case rl78 = 73
    case rx = 74
    case wasm = 75
    case nds32 = 76
    case mcore = 77
}
```

- [ ] **Step 2: Add `processor` and `addressBounds` convenience properties**

Add inside the `Database` enum, after the existing `processorID()` function (around line 117):

```swift
    /// Typed processor identifier.
    public static var processor: ProcessorID {
        get throws(IDAError) {
            let rawID = try processorID()
            guard let id = ProcessorID(rawValue: rawID) else {
                throw IDAError(category: .unsupported, code: rawID,
                               message: "unknown processor ID: \(rawID)")
            }
            return id
        }
    }

    /// Address range of the database (min..max).
    public static var addressBounds: (start: Address, end: Address) {
        get throws(IDAError) {
            (try minAddress(), try maxAddress())
        }
    }
```

- [ ] **Step 3: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add bindings/swift/Sources/IDAX/Database.swift
git commit -m "feat(swift): add ProcessorID enum and Database convenience properties"
```

---

### Task 4: Fix `GraphLayout` to match C++ values

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Graph.swift`

**Important:** The C++ `ida::graph::Layout` enum has: None=0, Digraph=1, Tree=2, Circle=3, PolarTree=4, Orthogonal=5, RadialTree=6. The current Swift enum has incorrect raw values (tree=0, orthogonal=1, radial=2, circular=3). Must verify what the C shim `idax_graph_set_layout` passes to the C++ API — if it passes the int directly, the Swift values must match C++. Check the shim implementation at `idax_shim.cpp` for `idax_graph_set_layout` to confirm.

- [ ] **Step 1: Read the C shim implementation for graph layout**

Read `bindings/rust/idax-sys/shim/idax_shim.cpp` and search for `idax_graph_set_layout` to see if it passes the raw int directly or does mapping.

- [ ] **Step 2: Update the GraphLayout enum**

Replace the existing `GraphLayout` enum at line 37–42 in `Graph.swift`:

```swift
public enum GraphLayout: Int32, Sendable {
    case none = 0
    case digraph = 1
    case tree = 2
    case circle = 3
    case polarTree = 4
    case orthogonal = 5
    case radialTree = 6
}
```

If the C shim does mapping (unlikely), adjust values accordingly.

- [ ] **Step 3: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add bindings/swift/Sources/IDAX/Graph.swift
git commit -m "fix(swift): correct GraphLayout raw values to match C++ enum"
```

---

### Task 5: Add `Segment.first`/`last` convenience properties

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Segment.swift`

- [ ] **Step 1: Add the convenience properties**

Add after the existing `all()` function in the `Segment` extension (the static functions section):

```swift
    /// First segment in database order.
    public static var first: Segment {
        get throws(IDAError) {
            try byIndex(0)
        }
    }

    /// Last segment in database order.
    public static var last: Segment {
        get throws(IDAError) {
            let totalCount = try count()
            guard totalCount > 0 else {
                throw IDAError(category: .notFound, code: 0, message: "no segments in database")
            }
            return try byIndex(totalCount - 1)
        }
    }
```

- [ ] **Step 2: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add bindings/swift/Sources/IDAX/Segment.swift
git commit -m "feat(swift): add Segment.first and Segment.last convenience properties"
```

---

### Task 6: Add Diagnostics convenience functions

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Diagnostics.swift`

- [ ] **Step 1: Add `enrich` and `assertInvariant`**

Add at the end of the `Diagnostics` enum (before the closing `}`):

```swift
    /// Append context to an error's message.
    public static func enrich(_ error: IDAError, context: String) -> IDAError {
        let enrichedMessage: String
        if error.message.isEmpty {
            enrichedMessage = context
        } else {
            enrichedMessage = error.message + "; " + context
        }
        return IDAError(category: error.category, code: error.code,
                        message: enrichedMessage)
    }

    /// Assert an invariant, throwing if the condition is false.
    public static func assertInvariant(_ condition: Bool, _ message: String) throws(IDAError) {
        guard condition else {
            throw IDAError(category: .internal, code: 0,
                           message: "invariant violation: \(message)")
        }
    }
```

- [ ] **Step 2: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add bindings/swift/Sources/IDAX/Diagnostics.swift
git commit -m "feat(swift): add Diagnostics.enrich and assertInvariant"
```

---

### Task 7: Add `TypeHandle.ensureNamedType`

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Types.swift`

- [ ] **Step 1: Add the function**

Add after the existing `importType` function in the `TypeHandle` struct:

```swift
    /// Ensure a named type exists in the local type library.
    ///
    /// Looks up the type by name first; if not found, imports it from the
    /// specified source library (or the default library if empty), then
    /// looks it up again.
    public static func ensureNamedType(_ typeName: String,
                                       source: String = "") throws(IDAError) -> TypeHandle {
        if let existing = try? TypeHandle.byName(typeName) {
            return existing
        }
        try TypeHandle.importType(from: source, typeName: typeName)
        return try TypeHandle.byName(typeName)
    }
```

- [ ] **Step 2: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add bindings/swift/Sources/IDAX/Types.swift
git commit -m "feat(swift): add TypeHandle.ensureNamedType convenience"
```

---

### Task 8: Add CrossReference filter predicates

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Xref.swift`

**Reference:** `ReferenceType` enum at lines 5–9 has: unknown=0, flow, callNear, callFar, jumpNear, jumpFar, offset, read, write, text, informational. `CrossReference` struct at lines 22–28 has `isCode: Bool` and `type: ReferenceType`.

- [ ] **Step 1: Add filter predicates**

Add after the `CrossReference` struct definition:

```swift
extension CrossReference {
    /// True if this is a call reference (near or far).
    public var isCall: Bool {
        isCode && (type == .callNear || type == .callFar)
    }

    /// True if this is a jump reference (near or far).
    public var isJump: Bool {
        isCode && (type == .jumpNear || type == .jumpFar)
    }

    /// True if this is an ordinary code flow reference.
    public var isFlow: Bool {
        isCode && type == .flow
    }

    /// True if this is any kind of data reference.
    public var isDataReference: Bool {
        !isCode
    }

    /// True if this is a data read reference.
    public var isDataRead: Bool {
        !isCode && type == .read
    }

    /// True if this is a data write reference.
    public var isDataWrite: Bool {
        !isCode && type == .write
    }
}
```

- [ ] **Step 2: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add bindings/swift/Sources/IDAX/Xref.swift
git commit -m "feat(swift): add CrossReference filter predicates"
```

---

### Task 9: Add `DecompilerView` struct

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Decompiler.swift`

**Reference:** Current functions at lines 862–878 return raw `Address`. Replace with a struct.

- [ ] **Step 1: Add the `DecompilerView` struct**

Insert before the `Decompiler` enum's view functions (around line 860):

```swift
/// Lightweight handle to a decompiler pseudocode view.
public struct DecompilerView: Sendable {
    /// Address of the function being displayed.
    public let functionAddress: Address

    /// Get the decompiler view currently active in the UI.
    public static var current: DecompilerView {
        get throws(IDAError) {
            let address = try withOutput("decompiler.currentView", UInt64(0)) {
                idax_decompiler_current_view($0)
            }
            return DecompilerView(functionAddress: address)
        }
    }

    /// Get a decompiler view from an opaque host pointer (e.g., from plugin context).
    public static func fromHost(_ viewHost: UnsafeMutableRawPointer) throws(IDAError) -> DecompilerView {
        let address = try withOutput("decompiler.viewFromHost", UInt64(0)) {
            idax_decompiler_view_from_host(viewHost, $0)
        }
        return DecompilerView(functionAddress: address)
    }

    /// Get or create a decompiler view for a function.
    public static func forFunction(at address: Address) throws(IDAError) -> DecompilerView {
        let functionAddress = try withOutput("decompiler.viewForFunction", UInt64(0)) {
            idax_decompiler_view_for_function(address, $0)
        }
        return DecompilerView(functionAddress: functionAddress)
    }
}
```

- [ ] **Step 2: Remove the old static functions from `Decompiler` enum**

Delete the three functions `currentView()`, `viewFromHost(_:)`, and `viewForFunction(at:)` from the `Decompiler` enum (around lines 862–878). They are now on `DecompilerView`.

- [ ] **Step 3: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add bindings/swift/Sources/IDAX/Decompiler.swift
git commit -m "feat(swift): add DecompilerView struct, replace raw Address returns"
```

---

### Task 10: Fix `Data.writeTyped` for string/bytes/array

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Data.swift`

**Reference:** Current implementation at lines 210–219 only populates scalar fields. The `IdaxDataTypedValue` C struct has `string_value`, `bytes`, `byte_count`, `elements`, `element_count` fields.

- [ ] **Step 1: Check the C shim struct definition**

Read `bindings/swift/Sources/CIDAX/include/idax_shim.h` and search for `IdaxDataTypedValue` to find the exact field names.

- [ ] **Step 2: Update `writeTyped` to handle all value kinds**

Replace the `writeTyped` function body (around lines 210–219):

```swift
    public static func writeTyped(_ value: TypedValue, at address: Address,
                                  type: borrowing TypeHandle) throws(IDAError) {
        var raw = IdaxDataTypedValue()
        raw.kind = value.kind.rawValue
        raw.unsigned_value = value.unsignedValue
        raw.signed_value = value.signedValue
        raw.floating_value = value.floatingValue
        raw.pointer_value = value.pointerValue

        switch value.kind {
        case .string:
            try value.stringValue.withCString { cString in
                raw.string_value = UnsafeMutablePointer(mutating: cString)
                try checkStatus(idax_data_write_typed(address, type.handle, &raw), "data.writeTyped")
            }
        case .bytes:
            try value.bytes.withUnsafeBufferPointer { buffer in
                raw.bytes = UnsafeMutablePointer(mutating: buffer.baseAddress)
                raw.byte_count = buffer.count
                try checkStatus(idax_data_write_typed(address, type.handle, &raw), "data.writeTyped")
            }
        case .array:
            // Array elements are recursively encoded — for now pass the scalar
            // fields through; full recursive array support requires C shim changes.
            try checkStatus(idax_data_write_typed(address, type.handle, &raw), "data.writeTyped")
        case .unsignedInteger, .signedInteger, .floatingPoint, .pointer:
            try checkStatus(idax_data_write_typed(address, type.handle, &raw), "data.writeTyped")
        }
    }
```

**Note:** The exact field names (`string_value`, `bytes`, `byte_count`) must be verified against the C struct. Adjust if the C struct uses different names.

- [ ] **Step 3: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`

- [ ] **Step 4: Commit**

```bash
git add bindings/swift/Sources/IDAX/Data.swift
git commit -m "fix(swift): complete Data.writeTyped for string and bytes types"
```

---

### Task 11: Rename `widgetId` → `widgetID` in UI.swift

**Files:**
- Modify: `bindings/swift/Sources/IDAX/UI.swift`

**Occurrences to rename (from exploration):**
- Line 9: doc comment `widgetId` / `previousWidgetId`
- Line 14: `public let widgetId: UInt64` → `widgetID` (UIEvent)
- Line 15: `public let previousWidgetId: UInt64` → `previousWidgetID` (UIEvent)
- Line 34: `public let widgetId: UInt64` → `widgetID` (PopupEvent)
- Line 120: `public var widgetId: UInt64` → `widgetID` (Widget)
- Line 122: string label `"ui.widgetId"` → `"ui.widgetID"`
- Line 940: `widgetId:` → `widgetID:` (UIEvent initializer)
- Line 941: `previousWidgetId:` → `previousWidgetID:` (UIEvent initializer)
- Line 950: `widgetId:` → `widgetID:` (PopupEvent initializer)

- [ ] **Step 1: Perform the rename**

Use find-and-replace across the file. Replace all occurrences of `widgetId` with `widgetID` and `previousWidgetId` with `previousWidgetID`. This is a simple text replacement — use `replace_all`.

- [ ] **Step 2: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20`

- [ ] **Step 3: Commit**

```bash
git add bindings/swift/Sources/IDAX/UI.swift
git commit -m "fix(swift): rename widgetId to widgetID per Swift naming conventions"
```

---

### Task 12: Fix hardcoded test path + add Step 1 unit tests

**Files:**
- Modify: `bindings/swift/Tests/IDAXTests/UnitTests.swift`

- [ ] **Step 1: Fix the hardcoded database path**

Replace the hardcoded path at line 380:

```swift
    @Test func test() async throws {
        guard let databasePath = ProcessInfo.processInfo.environment["IDAX_TEST_DATABASE"] else {
            print("IDAX_TEST_DATABASE not set, skipping integration test")
            return
        }
```

Also add `import Foundation` at the top of the file if not already present (needed for `ProcessInfo`).

- [ ] **Step 2: Add unit tests for new enums and convenience functions**

Append before the closing of the file (before the `RuntimeTests` suite or at the end):

```swift
// MARK: - CallingConvention

@Suite("IDA CallingConvention")
struct CallingConventionTests {
    @Test func rawValues() {
        #expect(CallingConvention.unknown.rawValue == 0)
        #expect(CallingConvention.cdecl.rawValue == 1)
        #expect(CallingConvention.stdcall.rawValue == 2)
        #expect(CallingConvention.pascal.rawValue == 3)
        #expect(CallingConvention.fastcall.rawValue == 4)
        #expect(CallingConvention.thiscall.rawValue == 5)
        #expect(CallingConvention.swift.rawValue == 6)
        #expect(CallingConvention.golang.rawValue == 7)
        #expect(CallingConvention.userDefined.rawValue == 8)
    }

    @Test func unknownRawValueReturnsNil() {
        #expect(CallingConvention(rawValue: -1) == nil)
        #expect(CallingConvention(rawValue: 9) == nil)
    }
}

// MARK: - Color

@Suite("IDA Color")
struct ColorTests {
    @Test func representativeRawValues() {
        #expect(Color.default.rawValue == 0x01)
        #expect(Color.instruction.rawValue == 0x05)
        #expect(Color.number.rawValue == 0x0C)
        #expect(Color.keyword.rawValue == 0x20)
        #expect(Color.collapsed.rawValue == 0x27)
    }

    @Test func unknownRawValueReturnsNil() {
        #expect(Color(rawValue: 0x00) == nil)
        #expect(Color(rawValue: 0x28) == nil)
    }

    @Test func tagConstants() {
        #expect(Color.tagOn == 0x01)
        #expect(Color.tagOff == 0x02)
        #expect(Color.tagEscape == 0x03)
        #expect(Color.tagInverse == 0x04)
        #expect(Color.addressTag == 0x28)
        #expect(Color.addressTagSize == 16)
    }
}

// MARK: - ProcessorID

@Suite("IDA ProcessorID")
struct ProcessorIDTests {
    @Test func representativeRawValues() {
        #expect(ProcessorID.intelX86.rawValue == 0)
        #expect(ProcessorID.arm.rawValue == 13)
        #expect(ProcessorID.mips.rawValue == 12)
        #expect(ProcessorID.riscV.rawValue == 72)
        #expect(ProcessorID.wasm.rawValue == 75)
        #expect(ProcessorID.mcore.rawValue == 77)
    }

    @Test func unknownRawValueReturnsNil() {
        #expect(ProcessorID(rawValue: -1) == nil)
        #expect(ProcessorID(rawValue: 78) == nil)
    }
}

// MARK: - GraphLayout

@Suite("IDA GraphLayout")
struct GraphLayoutTests {
    @Test func allRawValues() {
        #expect(GraphLayout.none.rawValue == 0)
        #expect(GraphLayout.digraph.rawValue == 1)
        #expect(GraphLayout.tree.rawValue == 2)
        #expect(GraphLayout.circle.rawValue == 3)
        #expect(GraphLayout.polarTree.rawValue == 4)
        #expect(GraphLayout.orthogonal.rawValue == 5)
        #expect(GraphLayout.radialTree.rawValue == 6)
    }
}

// MARK: - CrossReference Predicates

@Suite("IDA CrossReference Predicates")
struct CrossReferencePredicateTests {
    @Test func isCall() {
        let callNear = CrossReference(from: 0, to: 1, isCode: true,
                                      type: .callNear, isUserDefined: false)
        let callFar = CrossReference(from: 0, to: 1, isCode: true,
                                     type: .callFar, isUserDefined: false)
        let jump = CrossReference(from: 0, to: 1, isCode: true,
                                  type: .jumpNear, isUserDefined: false)
        #expect(callNear.isCall)
        #expect(callFar.isCall)
        #expect(!jump.isCall)
    }

    @Test func isJump() {
        let jumpNear = CrossReference(from: 0, to: 1, isCode: true,
                                      type: .jumpNear, isUserDefined: false)
        let jumpFar = CrossReference(from: 0, to: 1, isCode: true,
                                     type: .jumpFar, isUserDefined: false)
        #expect(jumpNear.isJump)
        #expect(jumpFar.isJump)
    }

    @Test func isFlow() {
        let flow = CrossReference(from: 0, to: 1, isCode: true,
                                  type: .flow, isUserDefined: false)
        #expect(flow.isFlow)
    }

    @Test func dataPredicates() {
        let read = CrossReference(from: 0, to: 1, isCode: false,
                                  type: .read, isUserDefined: false)
        let write = CrossReference(from: 0, to: 1, isCode: false,
                                   type: .write, isUserDefined: false)
        #expect(read.isDataReference)
        #expect(read.isDataRead)
        #expect(!read.isDataWrite)
        #expect(write.isDataWrite)
        #expect(!write.isDataRead)
    }
}

// MARK: - Diagnostics Convenience

@Suite("IDA Diagnostics Convenience")
struct DiagnosticsConvenienceTests {
    @Test func enrichAppendsContext() {
        let original = IDAError(category: .notFound, code: 1, message: "symbol missing")
        let enriched = Diagnostics.enrich(original, context: "in function foo")
        #expect(enriched.message == "symbol missing; in function foo")
        #expect(enriched.category == .notFound)
        #expect(enriched.code == 1)
    }

    @Test func enrichEmptyMessage() {
        let original = IDAError(category: .internal, code: 0, message: "")
        let enriched = Diagnostics.enrich(original, context: "context only")
        #expect(enriched.message == "context only")
    }

    @Test func assertInvariantPasses() throws {
        try Diagnostics.assertInvariant(true, "should pass")
    }

    @Test func assertInvariantFails() {
        #expect(throws: IDAError.self) {
            try Diagnostics.assertInvariant(false, "expected failure")
        }
    }
}

// MARK: - DecompilerView

@Suite("IDA DecompilerView")
struct DecompilerViewTests {
    @Test func construction() {
        let view = DecompilerView(functionAddress: 0x401000)
        #expect(view.functionAddress == 0x401000)
    }
}
```

- [ ] **Step 3: Run tests**

Run: `cd /Volumes/Code/Personal/idax && swift test 2>&1 | tail -30`
Expected: All tests pass (new + existing)

- [ ] **Step 4: Commit**

```bash
git add bindings/swift/Tests/IDAXTests/UnitTests.swift
git commit -m "test(swift): add unit tests for Step 1 enums and convenience functions"
```

---

## Step 2: Decompiler Enhancements (C Shim + Swift)

### Task 13: Add decompiler C shim declarations

**Files:**
- Modify: `bindings/swift/Sources/CIDAX/include/idax_shim.h`
- Modify: `bindings/rust/idax-sys/shim/idax_shim.h`

- [ ] **Step 1: Read current decompiler section end**

Read both `.h` files to find where the decompiler section ends (after ctree functions, before the next section). The Swift shim's decompiler section ends around line 1570 (before Storage or Debugger section).

- [ ] **Step 2: Add new declarations to Swift shim**

Insert at the end of the decompiler section in `bindings/swift/Sources/CIDAX/include/idax_shim.h`:

```c
/* DecompiledFunction extended operations */
int idax_decompiled_retype_variable(void* handle, const char* variable_name,
                                     const char* type_declaration);
int idax_decompiled_retype_variable_by_index(void* handle, size_t variable_index,
                                              IdaxTypeHandle type_handle);
int idax_decompiled_refresh(void* handle);
int idax_decompiled_has_orphan_comments(void* handle, int* out_result);
int idax_decompiled_remove_orphan_comments(void* handle, int* out_removed_count);
int idax_decompiled_address_map(void* handle, uint64_t** out_line_numbers,
                                 uint64_t** out_addresses, size_t* out_count);
void idax_decompiled_address_map_free(uint64_t* line_numbers, uint64_t* addresses);
int idax_decompiled_microcode_lines(void* handle, char*** out_lines, size_t* out_count);

/* Extended ctree visitor with leave callbacks */
typedef int (*IdaxCtreeExprLeaveVisitor)(void* context, const void* expr_handle);
typedef int (*IdaxCtreeStmtLeaveVisitor)(void* context, const void* stmt_handle);

int idax_ctree_visit_ex(void* handle,
                         IdaxCtreeExprVisitor visit_expr,
                         IdaxCtreeStmtVisitor visit_stmt,
                         IdaxCtreeExprLeaveVisitor leave_expr,
                         IdaxCtreeStmtLeaveVisitor leave_stmt,
                         void* context,
                         int post_order,
                         int* out_visited);
```

- [ ] **Step 3: Add same declarations to Rust shim**

Copy the same declarations to `bindings/rust/idax-sys/shim/idax_shim.h` at the same location.

- [ ] **Step 4: Commit**

```bash
git add bindings/swift/Sources/CIDAX/include/idax_shim.h bindings/rust/idax-sys/shim/idax_shim.h
git commit -m "feat(shim): declare decompiler extension functions in C headers"
```

---

### Task 14: Implement decompiler C shim functions

**Files:**
- Modify: `bindings/rust/idax-sys/shim/idax_shim.cpp`

**Pattern reference:** `idax_decompiled_pseudocode` at line 4695 casts `handle` to `DecompiledFunction*` then uses `RETURN_RESULT_STRING`. `idax_ctree_visit` at line 4975 uses a local `Visitor` subclass of `CtreeVisitor`.

- [ ] **Step 1: Read the existing decompiler implementation section**

Find the end of the current decompiler section in `idax_shim.cpp` (after `idax_ctree_visit` and related functions).

- [ ] **Step 2: Add implementations**

Append after the existing decompiler section:

```cpp
// --- Decompiler extensions ---

int idax_decompiled_retype_variable(void* handle, const char* variable_name,
                                     const char* type_declaration) {
    auto* df = static_cast<ida::decompiler::DecompiledFunction*>(handle);
    auto type_result = ida::type::TypeInfo::from_declaration(type_declaration);
    if (!type_result) return fail(type_result.error());
    RETURN_STATUS(df->retype_variable(variable_name, *type_result));
}

int idax_decompiled_retype_variable_by_index(void* handle, size_t variable_index,
                                              IdaxTypeHandle type_handle) {
    auto* df = static_cast<ida::decompiler::DecompiledFunction*>(handle);
    auto* ti = static_cast<ida::type::TypeInfo*>(type_handle);
    RETURN_STATUS(df->retype_variable(variable_index, *ti));
}

int idax_decompiled_refresh(void* handle) {
    auto* df = static_cast<ida::decompiler::DecompiledFunction*>(handle);
    RETURN_STATUS(df->refresh());
}

int idax_decompiled_has_orphan_comments(void* handle, int* out_result) {
    auto* df = static_cast<ida::decompiler::DecompiledFunction*>(handle);
    auto r = df->has_orphan_comments();
    if (!r) return fail(r.error());
    *out_result = *r ? 1 : 0;
    return 0;
}

int idax_decompiled_remove_orphan_comments(void* handle, int* out_removed_count) {
    auto* df = static_cast<ida::decompiler::DecompiledFunction*>(handle);
    RETURN_RESULT_VALUE(df->remove_orphan_comments());
}

int idax_decompiled_address_map(void* handle, uint64_t** out_line_numbers,
                                 uint64_t** out_addresses, size_t* out_count) {
    clear_error();
    auto* df = static_cast<ida::decompiler::DecompiledFunction*>(handle);
    auto r = df->address_map();
    if (!r) return fail(r.error());
    auto& mappings = *r;
    size_t count = mappings.size();
    auto* lines = static_cast<uint64_t*>(malloc(count * sizeof(uint64_t)));
    auto* addrs = static_cast<uint64_t*>(malloc(count * sizeof(uint64_t)));
    if (!lines || !addrs) {
        free(lines);
        free(addrs);
        return fail(ida::Error::internal("malloc failed"));
    }
    for (size_t i = 0; i < count; ++i) {
        lines[i] = static_cast<uint64_t>(mappings[i].line_number);
        addrs[i] = mappings[i].address;
    }
    *out_line_numbers = lines;
    *out_addresses = addrs;
    *out_count = count;
    return 0;
}

void idax_decompiled_address_map_free(uint64_t* line_numbers, uint64_t* addresses) {
    free(line_numbers);
    free(addresses);
}

int idax_decompiled_microcode_lines(void* handle, char*** out_lines, size_t* out_count) {
    clear_error();
    auto* df = static_cast<ida::decompiler::DecompiledFunction*>(handle);
    auto r = df->microcode_lines();
    if (!r) return fail(r.error());
    auto& vec = *r;
    size_t count = vec.size();
    auto** arr = static_cast<char**>(malloc(count * sizeof(char*)));
    if (!arr) return fail(ida::Error::internal("malloc failed"));
    for (size_t i = 0; i < count; ++i) {
        arr[i] = dup_string(vec[i]);
    }
    *out_lines = arr;
    *out_count = count;
    return 0;
}

int idax_ctree_visit_ex(void* handle,
                         IdaxCtreeExprVisitor visit_expr,
                         IdaxCtreeStmtVisitor visit_stmt,
                         IdaxCtreeExprLeaveVisitor leave_expr,
                         IdaxCtreeStmtLeaveVisitor leave_stmt,
                         void* context,
                         int post_order,
                         int* out_visited) {
    clear_error();
    auto* df = static_cast<ida::decompiler::DecompiledFunction*>(handle);
    ida::decompiler::VisitOptions opts;
    opts.post_order = (post_order != 0);

    class VisitorEx : public ida::decompiler::CtreeVisitor {
    public:
        IdaxCtreeExprVisitor visit_expr_;
        IdaxCtreeStmtVisitor visit_stmt_;
        IdaxCtreeExprLeaveVisitor leave_expr_;
        IdaxCtreeStmtLeaveVisitor leave_stmt_;
        void* ctx_;

        VisitorEx(IdaxCtreeExprVisitor ve, IdaxCtreeStmtVisitor vs,
                  IdaxCtreeExprLeaveVisitor le, IdaxCtreeStmtLeaveVisitor ls,
                  void* c)
            : visit_expr_(ve), visit_stmt_(vs),
              leave_expr_(le), leave_stmt_(ls), ctx_(c) {}

        ida::decompiler::VisitAction visit_expression(
                ida::decompiler::ExpressionView expr) override {
            if (!visit_expr_) return ida::decompiler::VisitAction::Continue;
            return visit_action_from_c_int(visit_expr_(ctx_, expr.raw_handle()));
        }
        ida::decompiler::VisitAction visit_statement(
                ida::decompiler::StatementView stmt) override {
            if (!visit_stmt_) return ida::decompiler::VisitAction::Continue;
            return visit_action_from_c_int(visit_stmt_(ctx_, stmt.raw_handle()));
        }
        ida::decompiler::VisitAction leave_expression(
                ida::decompiler::ExpressionView expr) override {
            if (!leave_expr_) return ida::decompiler::VisitAction::Continue;
            return visit_action_from_c_int(leave_expr_(ctx_, expr.raw_handle()));
        }
        ida::decompiler::VisitAction leave_statement(
                ida::decompiler::StatementView stmt) override {
            if (!leave_stmt_) return ida::decompiler::VisitAction::Continue;
            return visit_action_from_c_int(leave_stmt_(ctx_, stmt.raw_handle()));
        }
    };

    VisitorEx visitor(visit_expr, visit_stmt, leave_expr, leave_stmt, context);
    auto result = df->visit(visitor, opts);
    if (!result) return fail(result.error());
    *out_visited = *result;
    return 0;
}
```

- [ ] **Step 3: Commit**

```bash
git add bindings/rust/idax-sys/shim/idax_shim.cpp
git commit -m "feat(shim): implement decompiler extension functions"
```

---

### Task 15: Add Swift wrappers for decompiler extensions

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Decompiler.swift`

- [ ] **Step 1: Add `AddressMapping` type and new `DecompiledFunction` methods**

Add the `AddressMapping` struct near the other decompiler types:

```swift
/// Mapping between a pseudocode line number and a database address.
public struct AddressMapping: Sendable {
    public let lineNumber: Int
    public let address: Address
}
```

Add new methods to `DecompiledFunction`:

```swift
    /// Change the type of a local variable by name.
    public func retypeVariable(name: String, typeDeclaration: String) throws(IDAError) {
        try name.withCString { namePointer in
            try typeDeclaration.withCString { typePointer in
                try checkStatus(
                    idax_decompiled_retype_variable(handle, namePointer, typePointer),
                    "decompiled.retypeVariable"
                )
            }
        }
    }

    /// Change the type of a local variable by index.
    public func retypeVariable(at index: Int, type: borrowing TypeHandle) throws(IDAError) {
        try checkStatus(
            idax_decompiled_retype_variable_by_index(handle, index, type.handle),
            "decompiled.retypeVariableByIndex"
        )
    }

    /// Refresh the decompilation.
    public func refresh() throws(IDAError) {
        try checkStatus(idax_decompiled_refresh(handle), "decompiled.refresh")
    }

    /// Whether the decompilation contains orphan comments.
    public var hasOrphanComments: Bool {
        get throws(IDAError) {
            var out: Int32 = 0
            try checkStatus(idax_decompiled_has_orphan_comments(handle, &out),
                            "decompiled.hasOrphanComments")
            return out != 0
        }
    }

    /// Remove orphan comments. Returns the number removed.
    public func removeOrphanComments() throws(IDAError) -> Int {
        var out: Int32 = 0
        try checkStatus(idax_decompiled_remove_orphan_comments(handle, &out),
                        "decompiled.removeOrphanComments")
        return Int(out)
    }

    /// Line number to address mapping for the pseudocode.
    public var addressMap: [AddressMapping] {
        get throws(IDAError) {
            var lineNumbers: UnsafeMutablePointer<UInt64>?
            var addresses: UnsafeMutablePointer<UInt64>?
            var count: Int = 0
            try checkStatus(
                idax_decompiled_address_map(handle, &lineNumbers, &addresses, &count),
                "decompiled.addressMap"
            )
            defer { idax_decompiled_address_map_free(lineNumbers, addresses) }
            guard let lineNumbers, let addresses else { return [] }
            return (0..<count).map { index in
                AddressMapping(lineNumber: Int(lineNumbers[index]),
                               address: addresses[index])
            }
        }
    }

    /// Microcode text representation lines.
    public var microcodeLines: [String] {
        get throws(IDAError) {
            var rawLines: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
            var count: Int = 0
            try checkStatus(
                idax_decompiled_microcode_lines(handle, &rawLines, &count),
                "decompiled.microcodeLines"
            )
            defer {
                if let rawLines {
                    for index in 0..<count {
                        free(rawLines[index])
                    }
                    free(rawLines)
                }
            }
            guard let rawLines else { return [] }
            return (0..<count).map { index in
                rawLines[index].map { String(cString: $0) } ?? ""
            }
        }
    }
```

- [ ] **Step 2: Add extended `visitCtree` with leave callbacks**

Add a new overload of `visitCtree` on `DecompiledFunction`:

```swift
    /// Visit the ctree with both visit and leave callbacks.
    public func visitCtreeEx(
        postOrder: Bool = false,
        expressionVisitor: ((CtreeExpression) -> CtreeVisitAction)? = nil,
        statementVisitor: ((CtreeStatement) -> CtreeVisitAction)? = nil,
        expressionLeave: ((CtreeExpression) -> CtreeVisitAction)? = nil,
        statementLeave: ((CtreeStatement) -> CtreeVisitAction)? = nil
    ) throws(IDAError) -> Int {
        // If no leave callbacks, use the existing simpler visit
        guard expressionLeave != nil || statementLeave != nil else {
            return try visitCtree(postOrder: postOrder,
                                  expressionVisitor: expressionVisitor,
                                  statementVisitor: statementVisitor)
        }

        typealias VisitorBox = (
            visitExpr: ((CtreeExpression) -> CtreeVisitAction)?,
            visitStmt: ((CtreeStatement) -> CtreeVisitAction)?,
            leaveExpr: ((CtreeExpression) -> CtreeVisitAction)?,
            leaveStmt: ((CtreeStatement) -> CtreeVisitAction)?
        )
        var box: VisitorBox = (expressionVisitor, statementVisitor,
                                expressionLeave, statementLeave)

        let visitExprTrampoline: IdaxCtreeExprVisitor? = expressionVisitor != nil ? {
            ctx, exprHandle in
            let boxPtr = ctx!.assumingMemoryBound(to: VisitorBox.self)
            let expr = CtreeExpression(handle: exprHandle!)
            return boxPtr.pointee.visitExpr?(expr).rawValue ?? 0
        } : nil

        let visitStmtTrampoline: IdaxCtreeStmtVisitor? = statementVisitor != nil ? {
            ctx, stmtHandle in
            let boxPtr = ctx!.assumingMemoryBound(to: VisitorBox.self)
            let stmt = CtreeStatement(handle: stmtHandle!)
            return boxPtr.pointee.visitStmt?(stmt).rawValue ?? 0
        } : nil

        let leaveExprTrampoline: IdaxCtreeExprLeaveVisitor? = expressionLeave != nil ? {
            ctx, exprHandle in
            let boxPtr = ctx!.assumingMemoryBound(to: VisitorBox.self)
            let expr = CtreeExpression(handle: exprHandle!)
            return boxPtr.pointee.leaveExpr?(expr).rawValue ?? 0
        } : nil

        let leaveStmtTrampoline: IdaxCtreeStmtLeaveVisitor? = statementLeave != nil ? {
            ctx, stmtHandle in
            let boxPtr = ctx!.assumingMemoryBound(to: VisitorBox.self)
            let stmt = CtreeStatement(handle: stmtHandle!)
            return boxPtr.pointee.leaveStmt?(stmt).rawValue ?? 0
        } : nil

        var visitedCount: Int32 = 0
        try withUnsafeMutablePointer(to: &box) { boxPointer in
            try checkStatus(
                idax_ctree_visit_ex(handle,
                                     visitExprTrampoline,
                                     visitStmtTrampoline,
                                     leaveExprTrampoline,
                                     leaveStmtTrampoline,
                                     boxPointer,
                                     postOrder ? 1 : 0,
                                     &visitedCount),
                "decompiled.visitCtreeEx"
            )
        }
        return Int(visitedCount)
    }
```

**Note:** The trampoline closures and `VisitorBox` pattern must match the existing callback pattern used by `visitCtree`. Verify that `CtreeExpression(handle:)` and `CtreeStatement(handle:)` are the correct initializers — check the existing code.

- [ ] **Step 3: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -30`

- [ ] **Step 4: Commit**

```bash
git add bindings/swift/Sources/IDAX/Decompiler.swift
git commit -m "feat(swift): add decompiler extensions — retype, refresh, orphan comments, address map, microcode lines, leave visitors"
```

---

## Step 3: MicrocodeContext Mutations (C Shim + Swift)

### Task 16: Add MicrocodeContext mutation C shim declarations

**Files:**
- Modify: `bindings/swift/Sources/CIDAX/include/idax_shim.h`
- Modify: `bindings/rust/idax-sys/shim/idax_shim.h`

- [ ] **Step 1: Add new C structs and function declarations**

Insert in the decompiler section of both `.h` files, after the existing microcode context functions:

```c
/* MicrocodeContext mutation operations */

typedef enum {
    IdaxMicrocodeInsertPolicyAppend = 0,
    IdaxMicrocodeInsertPolicyPrepend = 1,
    IdaxMicrocodeInsertPolicyReplace = 2
} IdaxMicrocodeInsertPolicy;

int idax_microcode_context_remove_last_emitted(void* mctx);
int idax_microcode_context_remove_at_index(void* mctx, int index);
int idax_microcode_context_emit_noop(void* mctx, int policy);
int idax_microcode_context_emit_instruction(void* mctx,
    const IdaxMicrocodeInstruction* instr, int policy);
int idax_microcode_context_load_operand_register(void* mctx,
    int operand_index, int* out_reg);
int idax_microcode_context_load_effective_address_register(void* mctx,
    int operand_index, int* out_reg);
int idax_microcode_context_allocate_temporary_register(void* mctx,
    int byte_width, int* out_reg);
int idax_microcode_context_store_operand_register(void* mctx,
    int operand_index, int source_reg, int byte_width, int mark_udt);
int idax_microcode_context_emit_move_register(void* mctx,
    int src, int dst, int byte_width, int mark_udt, int policy);
int idax_microcode_context_emit_load_memory_register(void* mctx,
    int sel, int off, int dst, int byte_width, int off_byte_width,
    int mark_udt, int policy);
int idax_microcode_context_emit_store_memory_register(void* mctx,
    int src, int sel, int off, int byte_width, int off_byte_width,
    int mark_udt, int policy);
int idax_microcode_context_emit_helper_call(void* mctx, const char* name);
int idax_microcode_context_emit_helper_call_with_args(void* mctx,
    const char* name, const IdaxMicrocodeValue* args, size_t arg_count);
int idax_microcode_context_emit_helper_call_to_register(void* mctx,
    const char* name, const IdaxMicrocodeValue* args, size_t arg_count,
    int dst_reg, int dst_byte_width, int dst_unsigned);
int idax_microcode_context_emit_helper_call_to_operand(void* mctx,
    const char* name, const IdaxMicrocodeValue* args, size_t arg_count,
    int dst_operand_index, int dst_byte_width, int dst_unsigned);
```

Also add the `IdaxMicrocodeValue` struct if not already present:

```c
typedef struct {
    int kind;
    int location_kind;
    int64_t data;
    int byte_width;
} IdaxMicrocodeValue;
```

- [ ] **Step 2: Commit**

```bash
git add bindings/swift/Sources/CIDAX/include/idax_shim.h bindings/rust/idax-sys/shim/idax_shim.h
git commit -m "feat(shim): declare MicrocodeContext mutation functions"
```

---

### Task 17: Implement MicrocodeContext mutation C shim functions

**Files:**
- Modify: `bindings/rust/idax-sys/shim/idax_shim.cpp`

- [ ] **Step 1: Add implementations**

Each function casts `void* mctx` to `ida::decompiler::MicrocodeContext*` and calls the corresponding method. Follow the existing pattern of `clear_error()` + fail/return. The C++ `MicrocodeContext` methods mostly return `Status` (use `RETURN_STATUS`) or `Result<int>` (use `RETURN_RESULT_VALUE`).

Add after the existing microcode context read functions:

```cpp
// --- MicrocodeContext mutations ---

int idax_microcode_context_remove_last_emitted(void* mctx) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    RETURN_STATUS(ctx->remove_last_emitted_instruction());
}

int idax_microcode_context_remove_at_index(void* mctx, int index) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    RETURN_STATUS(ctx->remove_instruction_at_index(index));
}

int idax_microcode_context_emit_noop(void* mctx, int policy) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    if (policy == 0)
        RETURN_STATUS(ctx->emit_noop());
    else
        RETURN_STATUS(ctx->emit_noop_with_policy(
            static_cast<ida::decompiler::MicrocodeInsertPolicy>(policy)));
}

int idax_microcode_context_emit_instruction(void* mctx,
    const IdaxMicrocodeInstruction* instr, int policy) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    // Convert IdaxMicrocodeInstruction to ida::decompiler::MicrocodeInstruction
    ida::decompiler::MicrocodeInstruction mi{};
    mi.opcode = static_cast<ida::decompiler::MicrocodeOpcode>(instr->opcode);
    // Copy operand fields — left, right, destination
    auto convert_operand = [](const IdaxMicrocodeOperand& src) {
        ida::decompiler::MicrocodeOperand dst{};
        dst.kind = static_cast<ida::decompiler::MicrocodeOperandKind>(src.kind);
        dst.register_number = src.register_number;
        dst.value = src.value;
        dst.byte_width = src.byte_width;
        return dst;
    };
    mi.left = convert_operand(instr->left);
    mi.right = convert_operand(instr->right);
    mi.destination = convert_operand(instr->destination);
    mi.address = instr->address;

    if (policy == 0)
        RETURN_STATUS(ctx->emit_instruction(mi));
    else
        RETURN_STATUS(ctx->emit_instruction_with_policy(mi,
            static_cast<ida::decompiler::MicrocodeInsertPolicy>(policy)));
}

int idax_microcode_context_load_operand_register(void* mctx,
    int operand_index, int* out_reg) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    RETURN_RESULT_VALUE(ctx->load_operand_register(operand_index));
}

int idax_microcode_context_load_effective_address_register(void* mctx,
    int operand_index, int* out_reg) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    RETURN_RESULT_VALUE(ctx->load_effective_address_register(operand_index));
}

int idax_microcode_context_allocate_temporary_register(void* mctx,
    int byte_width, int* out_reg) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    RETURN_RESULT_VALUE(ctx->allocate_temporary_register(byte_width));
}

int idax_microcode_context_store_operand_register(void* mctx,
    int operand_index, int source_reg, int byte_width, int mark_udt) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    RETURN_STATUS(ctx->store_operand_register(operand_index, source_reg,
                                               byte_width, mark_udt != 0));
}

int idax_microcode_context_emit_move_register(void* mctx,
    int src, int dst, int byte_width, int mark_udt, int policy) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    if (policy == 0)
        RETURN_STATUS(ctx->emit_move_register(src, dst, byte_width, mark_udt != 0));
    else
        RETURN_STATUS(ctx->emit_move_register_with_policy(src, dst, byte_width,
            static_cast<ida::decompiler::MicrocodeInsertPolicy>(policy),
            mark_udt != 0));
}

int idax_microcode_context_emit_load_memory_register(void* mctx,
    int sel, int off, int dst, int byte_width, int off_byte_width,
    int mark_udt, int policy) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    if (policy == 0)
        RETURN_STATUS(ctx->emit_load_memory_register(sel, off, dst,
            byte_width, off_byte_width, mark_udt != 0));
    else
        RETURN_STATUS(ctx->emit_load_memory_register_with_policy(sel, off, dst,
            byte_width, off_byte_width,
            static_cast<ida::decompiler::MicrocodeInsertPolicy>(policy),
            mark_udt != 0));
}

int idax_microcode_context_emit_store_memory_register(void* mctx,
    int src, int sel, int off, int byte_width, int off_byte_width,
    int mark_udt, int policy) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    if (policy == 0)
        RETURN_STATUS(ctx->emit_store_memory_register(src, sel, off,
            byte_width, off_byte_width, mark_udt != 0));
    else
        RETURN_STATUS(ctx->emit_store_memory_register_with_policy(src, sel, off,
            byte_width, off_byte_width,
            static_cast<ida::decompiler::MicrocodeInsertPolicy>(policy),
            mark_udt != 0));
}

int idax_microcode_context_emit_helper_call(void* mctx, const char* name) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    RETURN_STATUS(ctx->emit_helper_call(name));
}

int idax_microcode_context_emit_helper_call_with_args(void* mctx,
    const char* name, const IdaxMicrocodeValue* args, size_t arg_count) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    std::vector<ida::decompiler::MicrocodeValue> values(arg_count);
    for (size_t i = 0; i < arg_count; ++i) {
        values[i].kind = static_cast<ida::decompiler::MicrocodeValueKind>(args[i].kind);
        values[i].location.kind = static_cast<ida::decompiler::MicrocodeValueLocationKind>(args[i].location_kind);
        values[i].data = args[i].data;
        values[i].byte_width = args[i].byte_width;
    }
    RETURN_STATUS(ctx->emit_helper_call_with_arguments(name, values));
}

int idax_microcode_context_emit_helper_call_to_register(void* mctx,
    const char* name, const IdaxMicrocodeValue* args, size_t arg_count,
    int dst_reg, int dst_byte_width, int dst_unsigned) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    std::vector<ida::decompiler::MicrocodeValue> values(arg_count);
    for (size_t i = 0; i < arg_count; ++i) {
        values[i].kind = static_cast<ida::decompiler::MicrocodeValueKind>(args[i].kind);
        values[i].location.kind = static_cast<ida::decompiler::MicrocodeValueLocationKind>(args[i].location_kind);
        values[i].data = args[i].data;
        values[i].byte_width = args[i].byte_width;
    }
    RETURN_STATUS(ctx->emit_helper_call_with_arguments_to_register(
        name, values, dst_reg, dst_byte_width, dst_unsigned != 0));
}

int idax_microcode_context_emit_helper_call_to_operand(void* mctx,
    const char* name, const IdaxMicrocodeValue* args, size_t arg_count,
    int dst_operand_index, int dst_byte_width, int dst_unsigned) {
    auto* ctx = static_cast<ida::decompiler::MicrocodeContext*>(mctx);
    std::vector<ida::decompiler::MicrocodeValue> values(arg_count);
    for (size_t i = 0; i < arg_count; ++i) {
        values[i].kind = static_cast<ida::decompiler::MicrocodeValueKind>(args[i].kind);
        values[i].location.kind = static_cast<ida::decompiler::MicrocodeValueLocationKind>(args[i].location_kind);
        values[i].data = args[i].data;
        values[i].byte_width = args[i].byte_width;
    }
    RETURN_STATUS(ctx->emit_helper_call_with_arguments_to_operand(
        name, values, dst_operand_index, dst_byte_width, dst_unsigned != 0));
}
```

**Note:** Field names on `MicrocodeValue` (e.g., `location.kind`, `data`, `byte_width`) must be verified against the actual C++ struct definitions in `include/ida/decompiler.hpp`. Adjust if they differ.

- [ ] **Step 2: Commit**

```bash
git add bindings/rust/idax-sys/shim/idax_shim.cpp
git commit -m "feat(shim): implement MicrocodeContext mutation functions"
```

---

### Task 18: Add Swift MicrocodeContext wrapper

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Decompiler.swift`

- [ ] **Step 1: Add `MicrocodeInsertPolicy` enum and `MicrocodeContext` struct**

Replace the existing static `microcodeContext*` functions on the `Decompiler` enum with a proper `MicrocodeContext` struct. Add near the other microcode types:

```swift
/// Insertion policy for microcode instructions.
public enum MicrocodeInsertPolicy: Int32, Sendable {
    case append = 0
    case prepend = 1
    case replace = 2
}

/// Microcode value for helper call arguments.
public struct MicrocodeValue: Sendable {
    public var kind: Int32
    public var locationKind: Int32
    public var data: Int64
    public var byteWidth: Int32

    public init(kind: Int32 = 0, locationKind: Int32 = 0,
                data: Int64 = 0, byteWidth: Int32 = 0) {
        self.kind = kind
        self.locationKind = locationKind
        self.data = data
        self.byteWidth = byteWidth
    }
}

/// Handle to the microcode generation context, available during filter callbacks.
///
/// This is a borrowed reference — valid only during the filter callback invocation.
/// Do not store or use after the callback returns.
public struct MicrocodeContext {
    let handle: UnsafeMutableRawPointer

    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    // MARK: - Read operations (existing, moved from Decompiler enum)

    public var address: Address {
        get throws(IDAError) {
            try withOutput("microcodeContext.address", UInt64(0)) {
                idax_decompiler_microcode_context_address(handle, $0)
            }
        }
    }

    public var instructionType: Int {
        get throws(IDAError) {
            var out: Int32 = 0
            try checkStatus(
                idax_decompiler_microcode_context_instruction_type(handle, &out),
                "microcodeContext.instructionType"
            )
            return Int(out)
        }
    }

    public var blockInstructionCount: Int {
        get throws(IDAError) {
            var out: Int32 = 0
            try checkStatus(
                idax_decompiler_microcode_context_block_instruction_count(handle, &out),
                "microcodeContext.blockInstructionCount"
            )
            return Int(out)
        }
    }

    public func hasInstruction(at index: Int) throws(IDAError) -> Bool {
        var out: Int32 = 0
        try checkStatus(
            idax_decompiler_microcode_context_has_instruction_at_index(handle, Int32(index), &out),
            "microcodeContext.hasInstruction"
        )
        return out != 0
    }

    public var hasLastEmittedInstruction: Bool {
        get throws(IDAError) {
            var out: Int32 = 0
            try checkStatus(
                idax_decompiler_microcode_context_has_last_emitted_instruction(handle, &out),
                "microcodeContext.hasLastEmitted"
            )
            return out != 0
        }
    }

    // MARK: - Mutation operations (new)

    public func removeLastEmittedInstruction() throws(IDAError) {
        try checkStatus(idax_microcode_context_remove_last_emitted(handle),
                        "microcodeContext.removeLastEmitted")
    }

    public func removeInstruction(at index: Int) throws(IDAError) {
        try checkStatus(idax_microcode_context_remove_at_index(handle, Int32(index)),
                        "microcodeContext.removeAtIndex")
    }

    public func emitNoop(policy: MicrocodeInsertPolicy = .append) throws(IDAError) {
        try checkStatus(idax_microcode_context_emit_noop(handle, policy.rawValue),
                        "microcodeContext.emitNoop")
    }

    public func emitInstruction(_ instruction: MicrocodeInstruction,
                                policy: MicrocodeInsertPolicy = .append) throws(IDAError) {
        var raw = instruction.toRaw()
        try checkStatus(
            idax_microcode_context_emit_instruction(handle, &raw, policy.rawValue),
            "microcodeContext.emitInstruction"
        )
    }

    public func loadOperandRegister(operandIndex: Int) throws(IDAError) -> Int {
        var out: Int32 = 0
        try checkStatus(
            idax_microcode_context_load_operand_register(handle, Int32(operandIndex), &out),
            "microcodeContext.loadOperandRegister"
        )
        return Int(out)
    }

    public func loadEffectiveAddressRegister(operandIndex: Int) throws(IDAError) -> Int {
        var out: Int32 = 0
        try checkStatus(
            idax_microcode_context_load_effective_address_register(handle, Int32(operandIndex), &out),
            "microcodeContext.loadEffectiveAddressRegister"
        )
        return Int(out)
    }

    public func allocateTemporaryRegister(byteWidth: Int) throws(IDAError) -> Int {
        var out: Int32 = 0
        try checkStatus(
            idax_microcode_context_allocate_temporary_register(handle, Int32(byteWidth), &out),
            "microcodeContext.allocateTemporaryRegister"
        )
        return Int(out)
    }

    public func storeOperandRegister(operandIndex: Int, source: Int,
                                     byteWidth: Int,
                                     markUserDefinedType: Bool = false) throws(IDAError) {
        try checkStatus(
            idax_microcode_context_store_operand_register(
                handle, Int32(operandIndex), Int32(source),
                Int32(byteWidth), markUserDefinedType ? 1 : 0),
            "microcodeContext.storeOperandRegister"
        )
    }

    public func emitMoveRegister(source: Int, destination: Int, byteWidth: Int,
                                 markUserDefinedType: Bool = false,
                                 policy: MicrocodeInsertPolicy = .append) throws(IDAError) {
        try checkStatus(
            idax_microcode_context_emit_move_register(
                handle, Int32(source), Int32(destination), Int32(byteWidth),
                markUserDefinedType ? 1 : 0, policy.rawValue),
            "microcodeContext.emitMoveRegister"
        )
    }

    public func emitLoadMemoryRegister(segment: Int, offset: Int, destination: Int,
                                       byteWidth: Int, offsetByteWidth: Int,
                                       markUserDefinedType: Bool = false,
                                       policy: MicrocodeInsertPolicy = .append) throws(IDAError) {
        try checkStatus(
            idax_microcode_context_emit_load_memory_register(
                handle, Int32(segment), Int32(offset), Int32(destination),
                Int32(byteWidth), Int32(offsetByteWidth),
                markUserDefinedType ? 1 : 0, policy.rawValue),
            "microcodeContext.emitLoadMemoryRegister"
        )
    }

    public func emitStoreMemoryRegister(source: Int, segment: Int, offset: Int,
                                        byteWidth: Int, offsetByteWidth: Int,
                                        markUserDefinedType: Bool = false,
                                        policy: MicrocodeInsertPolicy = .append) throws(IDAError) {
        try checkStatus(
            idax_microcode_context_emit_store_memory_register(
                handle, Int32(source), Int32(segment), Int32(offset),
                Int32(byteWidth), Int32(offsetByteWidth),
                markUserDefinedType ? 1 : 0, policy.rawValue),
            "microcodeContext.emitStoreMemoryRegister"
        )
    }

    public func emitHelperCall(_ name: String) throws(IDAError) {
        try name.withCString { namePointer in
            try checkStatus(
                idax_microcode_context_emit_helper_call(handle, namePointer),
                "microcodeContext.emitHelperCall"
            )
        }
    }

    public func emitHelperCall(_ name: String,
                               arguments: [MicrocodeValue]) throws(IDAError) {
        try name.withCString { namePointer in
            var rawArgs = arguments.map { arg in
                IdaxMicrocodeValue(kind: arg.kind, location_kind: arg.locationKind,
                                   data: arg.data, byte_width: arg.byteWidth)
            }
            try rawArgs.withUnsafeMutableBufferPointer { buffer in
                try checkStatus(
                    idax_microcode_context_emit_helper_call_with_args(
                        handle, namePointer, buffer.baseAddress, buffer.count),
                    "microcodeContext.emitHelperCallWithArgs"
                )
            }
        }
    }

    public func emitHelperCall(_ name: String, arguments: [MicrocodeValue],
                               destinationRegister: Int, byteWidth: Int,
                               unsigned: Bool = true) throws(IDAError) {
        try name.withCString { namePointer in
            var rawArgs = arguments.map { arg in
                IdaxMicrocodeValue(kind: arg.kind, location_kind: arg.locationKind,
                                   data: arg.data, byte_width: arg.byteWidth)
            }
            try rawArgs.withUnsafeMutableBufferPointer { buffer in
                try checkStatus(
                    idax_microcode_context_emit_helper_call_to_register(
                        handle, namePointer, buffer.baseAddress, buffer.count,
                        Int32(destinationRegister), Int32(byteWidth),
                        unsigned ? 1 : 0),
                    "microcodeContext.emitHelperCallToRegister"
                )
            }
        }
    }

    public func emitHelperCall(_ name: String, arguments: [MicrocodeValue],
                               destinationOperand: Int, byteWidth: Int,
                               unsigned: Bool = true) throws(IDAError) {
        try name.withCString { namePointer in
            var rawArgs = arguments.map { arg in
                IdaxMicrocodeValue(kind: arg.kind, location_kind: arg.locationKind,
                                   data: arg.data, byte_width: arg.byteWidth)
            }
            try rawArgs.withUnsafeMutableBufferPointer { buffer in
                try checkStatus(
                    idax_microcode_context_emit_helper_call_to_operand(
                        handle, namePointer, buffer.baseAddress, buffer.count,
                        Int32(destinationOperand), Int32(byteWidth),
                        unsigned ? 1 : 0),
                    "microcodeContext.emitHelperCallToOperand"
                )
            }
        }
    }
}
```

- [ ] **Step 2: Update `registerMicrocodeFilter` to pass `MicrocodeContext`**

Update the `apply` closure type in `registerMicrocodeFilter` to take `MicrocodeContext` instead of `UnsafeMutableRawPointer`:

```swift
    public static func registerMicrocodeFilter(
        match: @escaping (Address, Int) -> Bool,
        apply: @escaping (MicrocodeContext) -> Bool
    ) throws(IDAError) -> MicrocodeFilterSubscription {
```

Update the `MicrocodeFilterBox` and trampoline to wrap the raw pointer in a `MicrocodeContext`:

```swift
private final class MicrocodeFilterBox {
    let match: (Address, Int) -> Bool
    let apply: (MicrocodeContext) -> Bool

    init(match: @escaping (Address, Int) -> Bool,
         apply: @escaping (MicrocodeContext) -> Bool) {
        self.match = match
        self.apply = apply
    }
}
```

And in the apply trampoline:

```swift
    let context = MicrocodeContext(handle: mctx)
    return box.apply(context) ? 1 : 0
```

- [ ] **Step 3: Remove old static `microcodeContext*` functions from `Decompiler` enum**

The old functions like `Decompiler.microcodeContextAddress(_:)`, `Decompiler.microcodeContextInstructionType(_:)`, etc. are now methods on `MicrocodeContext`. Remove them from the `Decompiler` enum.

- [ ] **Step 4: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -30`

- [ ] **Step 5: Commit**

```bash
git add bindings/swift/Sources/IDAX/Decompiler.swift
git commit -m "feat(swift): add MicrocodeContext struct with mutation methods"
```

---

## Step 4: Processor Module (C Shim + Swift)

### Task 19: Add Processor C shim declarations

**Files:**
- Modify: `bindings/swift/Sources/CIDAX/include/idax_shim.h`
- Modify: `bindings/rust/idax-sys/shim/idax_shim.h`

- [ ] **Step 1: Add processor structs, callback table, and function declarations**

Replace the empty Processor section in both `.h` files with the full declaration. Use the exact enums from `include/ida/processor.hpp` (EmulateResult: NotImplemented=0, Success=1, DeleteInsn=-1; etc.). Note that `InstructionFeature` and `ProcessorFlag` are bitmasks.

The declarations should include: `IdaxRegisterInfo`, `IdaxInstructionDescriptor`, `IdaxAssemblerInfo`, `IdaxProcessorInfo`, `IdaxSwitchCase`, `IdaxSwitchDescription`, `IdaxProcessorCallbacks` (callback table struct), `idax_processor_register`, `idax_processor_unregister`, `idax_processor_info_free`, `idax_switch_description_free`, and ~20 `idax_output_context_*` functions.

**This task requires reading `include/ida/processor.hpp` for exact struct field lists and writing corresponding C structs.**

- [ ] **Step 2: Commit**

```bash
git add bindings/swift/Sources/CIDAX/include/idax_shim.h bindings/rust/idax-sys/shim/idax_shim.h
git commit -m "feat(shim): declare Processor module types and functions"
```

---

### Task 20: Implement Processor C shim functions

**Files:**
- Modify: `bindings/rust/idax-sys/shim/idax_shim.cpp`

- [ ] **Step 1: Implement the processor bridge**

Follow Pattern 5 (MicrocodeFilterBridge) — create a `ProcessorBridge` class that subclasses `ida::processor::Processor`, stores the `IdaxProcessorCallbacks` struct and `void* context`, and dispatches each virtual method to the corresponding C callback (null-checking optional ones).

Implement `idax_processor_register` (creates the bridge, registers it), `idax_processor_unregister`, free functions for structs, and all `idax_output_context_*` functions (each casts `void*` to `ida::processor::OutputContext*` and calls the method).

- [ ] **Step 2: Commit**

```bash
git add bindings/rust/idax-sys/shim/idax_shim.cpp
git commit -m "feat(shim): implement Processor module bridge and OutputContext"
```

---

### Task 21: Create Processor.swift

**Files:**
- Create: `bindings/swift/Sources/IDAX/Processor.swift`

- [ ] **Step 1: Create the file with all processor types and protocol**

Create `bindings/swift/Sources/IDAX/Processor.swift` containing:

1. `InstructionFeature` as `OptionSet` (bitmask, from C++ values)
2. `ProcessorFlag` as `OptionSet` (bitmask)
3. `EmulateResult` enum (notImplemented=0, success=1, deleteInstruction=-1)
4. `OutputOperandResult` enum (notImplemented=0, success=1, hidden=-1)
5. `OutputInstructionResult` enum (notImplemented=0, success=1)
6. `SwitchTableKind` enum
7. `RegisterInfo`, `InstructionDescriptor`, `AssemblerInfo`, `ProcessorInfo`, `SwitchCase`, `SwitchDescription` structs
8. `OutputContext` struct (~Copyable, wrapping `void*`, with ~20 methods calling `idax_output_context_*`)
9. `ProcessorModule` protocol (5 required + ~15 optional methods with default implementations)
10. `ProcessorRegistration` struct (~Copyable, RAII, calls `idax_processor_unregister` on deinit)
11. Private `ProcessorBox` class + trampoline functions for bridging protocol methods to C callbacks
12. Static `register(_:)` function

Follow the pattern established by `GraphCallbackHandler` protocol and `Graph.show(title:callbacks:)` for the callback bridging.

- [ ] **Step 2: Build to verify**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -30`

- [ ] **Step 3: Add unit tests for processor enums**

Add to `UnitTests.swift`:

```swift
@Suite("IDA Processor Enums")
struct ProcessorEnumTests {
    @Test func emulateResultRawValues() {
        #expect(EmulateResult.notImplemented.rawValue == 0)
        #expect(EmulateResult.success.rawValue == 1)
        #expect(EmulateResult.deleteInstruction.rawValue == -1)
    }

    @Test func instructionFeatureOptionSet() {
        let features: InstructionFeature = [.call, .jump]
        #expect(features.contains(.call))
        #expect(features.contains(.jump))
        #expect(!features.contains(.stop))
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd /Volumes/Code/Personal/idax && swift test 2>&1 | tail -20`

- [ ] **Step 5: Commit**

```bash
git add bindings/swift/Sources/IDAX/Processor.swift bindings/swift/Tests/IDAXTests/UnitTests.swift
git commit -m "feat(swift): add Processor module — protocol, OutputContext, registration"
```

---

## Step 5: Database + Core Enhancements (C Shim + Swift)

### Task 22: Add Database/Core C shim declarations and implementations

**Files:**
- Modify: `bindings/swift/Sources/CIDAX/include/idax_shim.h`
- Modify: `bindings/rust/idax-sys/shim/idax_shim.h`
- Modify: `bindings/rust/idax-sys/shim/idax_shim.cpp`

- [ ] **Step 1: Add declarations to both `.h` files**

In the Database section:

```c
typedef struct {
    int auto_load_plugins;       /* default 1 */
    int load_previous_database;  /* default 1 */
    const char* screen_palette;  /* NULL = default */
} IdaxRuntimeOptions;

int idax_database_init_with_options(const IdaxRuntimeOptions* options);
int idax_database_open_with_intent(const char* path, int intent, int mode);
```

- [ ] **Step 2: Add implementations to `.cpp`**

```cpp
int idax_database_init_with_options(const IdaxRuntimeOptions* options) {
    clear_error();
    ida::database::RuntimeOptions opts;
    if (options) {
        opts.auto_load_plugins = (options->auto_load_plugins != 0);
        opts.load_previous_database = (options->load_previous_database != 0);
        if (options->screen_palette)
            opts.screen_palette = options->screen_palette;
    }
    RETURN_STATUS(ida::database::init(opts));
}

int idax_database_open_with_intent(const char* path, int intent, int mode) {
    clear_error();
    auto load_intent = static_cast<ida::database::LoadIntent>(intent);
    auto open_mode = static_cast<ida::database::OpenMode>(mode);
    RETURN_STATUS(ida::database::open(path, load_intent, open_mode));
}
```

- [ ] **Step 3: Commit**

```bash
git add bindings/swift/Sources/CIDAX/include/idax_shim.h \
        bindings/rust/idax-sys/shim/idax_shim.h \
        bindings/rust/idax-sys/shim/idax_shim.cpp
git commit -m "feat(shim): add Database RuntimeOptions and LoadIntent support"
```

---

### Task 23: Add Swift Database/Core enhancements

**Files:**
- Modify: `bindings/swift/Sources/IDAX/Database.swift`

- [ ] **Step 1: Add new types and overloads**

Add near the top of `Database.swift` (with the other types):

```swift
/// How to open a database file.
public enum OpenMode: Int32, Sendable {
    case analyze = 0
    case skipAnalysis = 1
}

/// What kind of file to load.
public enum LoadIntent: Int32, Sendable {
    case autoDetect = 0
    case binary = 1
    case nonBinary = 2
}

/// Options for initializing the IDA runtime.
public struct RuntimeOptions: Sendable {
    public var autoLoadPlugins: Bool
    public var loadPreviousDatabase: Bool
    public var screenPalette: String?

    public init(autoLoadPlugins: Bool = true,
                loadPreviousDatabase: Bool = true,
                screenPalette: String? = nil) {
        self.autoLoadPlugins = autoLoadPlugins
        self.loadPreviousDatabase = loadPreviousDatabase
        self.screenPalette = screenPalette
    }
}
```

Add Core types (can go in Database.swift or a new section):

```swift
/// Common operation policy flags.
public struct OperationOptions: Sendable {
    public var strictValidation: Bool
    public var allowPartialResults: Bool
    public var cancelOnUserBreak: Bool
    public var quiet: Bool

    public init(strictValidation: Bool = true,
                allowPartialResults: Bool = false,
                cancelOnUserBreak: Bool = true,
                quiet: Bool = true) {
        self.strictValidation = strictValidation
        self.allowPartialResults = allowPartialResults
        self.cancelOnUserBreak = cancelOnUserBreak
        self.quiet = quiet
    }
}

/// Generic wait/poll policy.
public struct WaitOptions: Sendable {
    public var timeoutMilliseconds: UInt32
    public var pollIntervalMilliseconds: UInt32

    public init(timeoutMilliseconds: UInt32 = 0,
                pollIntervalMilliseconds: UInt32 = 10) {
        self.timeoutMilliseconds = timeoutMilliseconds
        self.pollIntervalMilliseconds = pollIntervalMilliseconds
    }
}
```

Add the new `Database` overloads:

```swift
    /// Initialize the IDA runtime with custom options.
    public static func initialize(options: RuntimeOptions) throws(IDAError) {
        var raw = IdaxRuntimeOptions()
        raw.auto_load_plugins = options.autoLoadPlugins ? 1 : 0
        raw.load_previous_database = options.loadPreviousDatabase ? 1 : 0
        if let palette = options.screenPalette {
            try palette.withCString { palettePointer in
                raw.screen_palette = palettePointer
                try checkStatus(idax_database_init_with_options(&raw), "database.initWithOptions")
            }
        } else {
            raw.screen_palette = nil
            try checkStatus(idax_database_init_with_options(&raw), "database.initWithOptions")
        }
        idax_sync_ida_globals()
    }

    /// Open a database with explicit intent and mode.
    public static func open(_ path: String, intent: LoadIntent = .autoDetect,
                            mode: OpenMode = .analyze) throws(IDAError) {
        try path.withCString { pathPointer in
            try checkStatus(
                idax_database_open_with_intent(pathPointer, intent.rawValue, mode.rawValue),
                "database.openWithIntent"
            )
        }
    }
```

- [ ] **Step 2: Add unit tests for new enums**

Add to `UnitTests.swift`:

```swift
@Suite("IDA OpenMode")
struct OpenModeTests {
    @Test func rawValues() {
        #expect(OpenMode.analyze.rawValue == 0)
        #expect(OpenMode.skipAnalysis.rawValue == 1)
    }
}

@Suite("IDA LoadIntent")
struct LoadIntentTests {
    @Test func rawValues() {
        #expect(LoadIntent.autoDetect.rawValue == 0)
        #expect(LoadIntent.binary.rawValue == 1)
        #expect(LoadIntent.nonBinary.rawValue == 2)
    }
}

@Suite("IDA RuntimeOptions")
struct RuntimeOptionsTests {
    @Test func defaults() {
        let options = RuntimeOptions()
        #expect(options.autoLoadPlugins)
        #expect(options.loadPreviousDatabase)
        #expect(options.screenPalette == nil)
    }
}

@Suite("IDA OperationOptions")
struct OperationOptionsTests {
    @Test func defaults() {
        let options = OperationOptions()
        #expect(options.strictValidation)
        #expect(!options.allowPartialResults)
        #expect(options.cancelOnUserBreak)
        #expect(options.quiet)
    }
}
```

- [ ] **Step 3: Build and test**

Run: `cd /Volumes/Code/Personal/idax && swift build 2>&1 | head -20 && swift test 2>&1 | tail -20`

- [ ] **Step 4: Commit**

```bash
git add bindings/swift/Sources/IDAX/Database.swift bindings/swift/Tests/IDAXTests/UnitTests.swift
git commit -m "feat(swift): add Database RuntimeOptions, OpenMode, LoadIntent, Core option types"
```

---

## Final: Update spec with corrections

### Task 24: Update spec with discovered corrections

**Files:**
- Modify: `docs/superpowers/specs/2026-03-31-swift-bindings-completeness-design.md`

- [ ] **Step 1: Update the spec**

Update the following corrections discovered during plan writing:
1. `CallingConvention` values: the C++ uses `Swift=6, Golang=7, UserDefined=8` (not manual/spoiled/reserved)
2. `GraphLayout` values: C++ uses `None=0, Digraph=1, Tree=2, Circle=3, PolarTree=4, Orthogonal=5, RadialTree=6` (completely different from the current Swift values)
3. `ProcessorID` values are the exact C++ values (78 cases, 0–77)
4. `InstructionFeature` and `ProcessorFlag` are `OptionSet` not `enum`
5. `EmulateResult` has a negative case (-1)

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-03-31-swift-bindings-completeness-design.md
git commit -m "docs: update spec with corrections from implementation plan"
```
