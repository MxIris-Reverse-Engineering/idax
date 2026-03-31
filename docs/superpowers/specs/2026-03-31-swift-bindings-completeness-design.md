# Swift Bindings Completeness — Design Spec

**Date:** 2026-03-31
**Branch:** `feat/swift-bindings`
**Scope:** Close all API gaps between the C++ library and the Swift bindings, using the Rust bindings as a reference.

## Overview

The Swift bindings currently wrap all 656 C shim functions with zero TODOs, covering 20 domain files. However, comparison against the full C++ API (`include/ida/`) and the Rust bindings reveals:

- Missing typed enums (raw `Int`/`UInt8` used instead)
- Missing convenience functions that Rust provides as pure-Rust compositions
- Partial `Data.writeTyped` implementation (string/bytes/array)
- C++ APIs not yet exposed in the C shim (decompiler enhancements, MicrocodeContext mutations, Processor module, Database options)
- Minor naming inconsistencies (`Id` vs `ID`)

The work is organized into 5 incremental steps, each independently testable.

---

## Step 1: Pure Swift Enums + Convenience Functions + Bug Fixes

No C shim changes. All modifications are in `bindings/swift/Sources/IDAX/` and `bindings/swift/Tests/`.

### 1.1 New Typed Enums

#### `CallingConvention` (Types.swift)

```swift
public enum CallingConvention: Int32, Sendable {
    case unknown = 0
    case cdecl = 1
    case stdcall = 2
    case pascal = 3
    case fastcall = 4
    case thiscall = 5
    case manual = 6
    case spoiled = 7
    case reserved = 8
}
```

Replace `functionType(callingConvention: Int)` parameter and `callingConvention: Int` property with this enum. Keep `init?(rawValue:)` failable for forward compatibility.

#### `Color` (Lines.swift)

```swift
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
}

extension Color {
    public static let tagOn: Character = "\u{01}"
    public static let tagOff: Character = "\u{02}"
    public static let tagEscape: Character = "\u{03}"
    public static let tagInverse: Character = "\u{04}"
    public static let addressTag: UInt8 = 0x28
    public static let addressTagSize: Int = 16
}
```

Update `Lines.colorString(_:color:)` to take `Color` instead of `UInt8`.

#### `ProcessorID` (Database.swift)

```swift
public enum ProcessorID: Int32, Sendable {
    case metapc = 0
    case ppc = 1
    case ppc64 = 2
    case arm = 3
    case arm64 = 4
    case mips = 5
    case mips64 = 6
    case sparc = 7
    case sparc64 = 8
    case alpha = 9
    case ia64 = 10
    case s390 = 11
    case s390x = 12
    case hppa = 13
    case m68k = 14
    case sh3 = 15
    case sh4 = 16
    case avr = 17
    case avr32 = 18
    case dalvik = 19
    case ebc = 20
    case msp430 = 21
    case c166 = 22
    case c39 = 23
    case cr16 = 24
    case fr = 25
    case h8 = 26
    case h8s = 27
    case java = 28
    case m16c = 29
    case m32r = 30
    case m740 = 31
    case m7700 = 32
    case m7900 = 33
    case mn102 = 34
    case pdp11 = 35
    case pic12 = 36
    case pic14 = 37
    case pic16 = 38
    case s1c = 39
    case sam8 = 40
    case spc700 = 41
    case st20 = 42
    case superH = 43
    case tlcs900 = 44
    case tricore = 45
    case tms320c1 = 46
    case tms320c2 = 47
    case tms320c3 = 48
    case tms320c5 = 49
    case tms320c54 = 50
    case tms320c55 = 51
    case tms320c6 = 52
    case v850 = 53
    case z80 = 54
    case z8 = 55
    case i51 = 56
    case i860 = 57
    case i960 = 58
    case f2mc = 59
    case trn = 60
    case nec78k = 61
    case nec850 = 62
    case unsp = 63
    case dsp56k = 64
    case ad218x = 65
    case oakdsp = 66
    case tlcs870 = 67
    case c54xp = 68
    case arc = 69
    case rl78 = 70
    case rx = 71
    case xtensa = 72
    case riscv = 73
    case wasm = 74
    case bpf = 75
    case evm = 76
}
```

**Note:** Exact raw values will be verified against `include/ida/database.hpp` `ProcessorId` enum at implementation time.

#### `GraphLayout` expansion (Graph.swift)

Add 3 new cases:

```swift
public enum GraphLayout: Int32, Sendable {
    case tree = 0
    case orthogonal = 1
    case radial = 2
    case circular = 3
    case hierarchical = 4
    case organic = 5
    case grid = 6
}
```

### 1.2 Convenience Functions (Pure Swift Compositions)

#### Segment (Segment.swift)

```swift
extension Segment {
    public static var first: Segment {
        get throws(IDAError) { try byIndex(0) }
    }

    public static var last: Segment {
        get throws(IDAError) {
            let totalCount = try count()
            guard totalCount > 0 else {
                throw IDAError(category: .notFound, code: 0, message: "no segments")
            }
            return try byIndex(totalCount - 1)
        }
    }
}
```

#### Database (Database.swift)

```swift
extension Database {
    public static var addressBounds: (start: Address, end: Address) {
        get throws(IDAError) {
            let start = try minAddress()
            let end = try maxAddress()
            return (start, end)
        }
    }

    public static var processor: ProcessorID {
        get throws(IDAError) {
            let rawID = try processorID()
            guard let processorID = ProcessorID(rawValue: rawID) else {
                throw IDAError(category: .unsupported, code: Int32(rawID),
                               message: "unknown processor ID: \(rawID)")
            }
            return processorID
        }
    }
}
```

#### Diagnostics (Diagnostics.swift)

```swift
extension Diagnostics {
    public static func enrich(_ error: IDAError, context: String) -> IDAError {
        var enrichedMessage = error.message
        if enrichedMessage.isEmpty {
            enrichedMessage = context
        } else {
            enrichedMessage += "; " + context
        }
        return IDAError(category: error.category, code: error.code,
                        message: enrichedMessage)
    }

    public static func assertInvariant(_ condition: Bool, _ message: String) throws(IDAError) {
        guard condition else {
            throw IDAError(category: .internal, code: 0,
                           message: "invariant violation: \(message)")
        }
    }
}
```

#### TypeHandle (Types.swift)

```swift
extension TypeHandle {
    public static func ensureNamedType(_ typeName: String,
                                       source: String = "") throws(IDAError) -> TypeHandle {
        if let existing = try? TypeHandle.byName(typeName) {
            return existing
        }
        try TypeHandle.importType(from: source, typeName: typeName)
        return try TypeHandle.byName(typeName)
    }
}
```

#### CrossReference filter predicates (Xref.swift)

```swift
extension CrossReference {
    public var isCall: Bool {
        isCode && (type == .callNear || type == .callFar)
    }
    public var isJump: Bool {
        isCode && (type == .jumpNear || type == .jumpFar)
    }
    public var isFlow: Bool {
        isCode && type == .flow
    }
    public var isData: Bool { !isCode }
    public var isDataRead: Bool {
        !isCode && type == .read
    }
    public var isDataWrite: Bool {
        !isCode && type == .write
    }
}
```

### 1.3 DecompilerView Struct

Replace raw `Address` returns with a lightweight struct:

```swift
public struct DecompilerView: Sendable {
    public let functionAddress: Address

    public static var current: DecompilerView {
        get throws(IDAError) {
            let address = try withOutput("decompiler.currentView", UInt64(0)) {
                idax_decompiler_current_view($0)
            }
            return DecompilerView(functionAddress: address)
        }
    }

    public static func fromHost(_ viewHost: UnsafeMutableRawPointer) throws(IDAError) -> DecompilerView {
        let address = try withOutput("decompiler.viewFromHost", UInt64(0)) {
            idax_decompiler_view_from_host(viewHost, $0)
        }
        return DecompilerView(functionAddress: address)
    }

    public static func forFunction(at address: Address) throws(IDAError) -> DecompilerView {
        let addr = try withOutput("decompiler.viewForFunction", UInt64(0)) {
            idax_decompiler_view_for_function(address, $0)
        }
        return DecompilerView(functionAddress: addr)
    }
}
```

### 1.4 Data.writeTyped Fix (Data.swift)

Complete the `IdaxDataTypedValue` construction for string, bytes, and array types in `writeTyped(_:at:type:)`. Currently only scalar types populate the C struct correctly. The fix:

- **String:** Set `kind = .string`, populate `stringValue` field, pass to C shim.
- **Bytes:** Set `kind = .bytes`, populate `bytes` + `byteCount` fields.
- **Array (elements):** Set `kind = .array`, populate `elements` + `elementCount` fields.

### 1.5 Naming Fix: `Id` → `ID`

Scan and fix all `Id` → `ID` occurrences in Swift sources:
- `UI.swift`: `widgetId` → `widgetID`, `previousWidgetId` → `previousWidgetID`
- Any other occurrences found via grep.

### 1.6 Hardcoded Test Path Cleanup (UnitTests.swift)

Replace the hardcoded path `/Volumes/RE/Xcode/26.2/...` with:

```swift
guard let databasePath = ProcessInfo.processInfo.environment["IDAX_TEST_DATABASE"] else {
    return // Skip integration test when env var not set
}
```

### 1.7 Unit Tests for New Enums

Add to `UnitTests.swift`:
- `CallingConvention` raw value round-trip tests
- `Color` representative raw values, unknown returns nil
- `ProcessorID` representative raw values
- `GraphLayout` all 7 raw values
- `CrossReference` filter predicate logic tests

---

## Step 2: Decompiler Enhancements (C Shim + Swift)

### 2.1 C Shim Additions

Files modified:
- `bindings/swift/Sources/CIDAX/include/idax_shim.h`
- `bindings/rust/idax-sys/shim/idax_shim.h`
- `bindings/rust/idax-sys/shim/idax_shim.cpp`

New functions:

```c
// Retype variable by name (resolves type from string declaration)
int idax_decompiled_retype_variable(void* handle, const char* variable_name,
                                     const char* type_declaration);

// Retype variable by index (uses existing TypeHandle)
int idax_decompiled_retype_variable_by_index(void* handle, size_t variable_index,
                                              IdaxTypeHandle type_handle);

// Refresh decompilation
int idax_decompiled_refresh(void* handle);

// Orphan comment management
int idax_decompiled_has_orphan_comments(void* handle, int* out_result);
int idax_decompiled_remove_orphan_comments(void* handle, int* out_removed_count);

// Address mapping (line number ↔ address)
int idax_decompiled_address_map(void* handle, uint64_t** out_line_numbers,
                                 uint64_t** out_addresses, size_t* out_count);
void idax_decompiled_address_map_free(uint64_t* line_numbers, uint64_t* addresses);

// Microcode text lines
int idax_decompiled_microcode_lines(void* handle, char*** out_lines, size_t* out_count);
// (reuses existing idax_decompiled_lines_free for cleanup)

// Extended ctree visitor with leave callbacks
int idax_ctree_visit_ex(void* handle, int post_order,
                         int (*visit_expression)(const void* expr, void* ctx),
                         int (*visit_statement)(const void* stmt, void* ctx),
                         int (*leave_expression)(const void* expr, void* ctx),
                         int (*leave_statement)(const void* stmt, void* ctx),
                         void* ctx);
```

### 2.2 Swift Wrapper

```swift
extension DecompiledFunction {
    public func retypeVariable(name: String, typeDeclaration: String) throws(IDAError)
    public func retypeVariable(at index: Int, type: borrowing TypeHandle) throws(IDAError)
    public func refresh() throws(IDAError)
    public var hasOrphanComments: Bool { get throws(IDAError) }
    public func removeOrphanComments() throws(IDAError) -> Int
    public var addressMap: [AddressMapping] { get throws(IDAError) }
    public var microcodeLines: [String] { get throws(IDAError) }
}

public struct AddressMapping: Sendable {
    public let lineNumber: Int
    public let address: Address
}
```

Extended `visitCtree` adds optional `expressionLeave` / `statementLeave` closure parameters (default `nil`). When all leave closures are nil, delegates to existing `idax_ctree_visit` for backward compat; otherwise calls `idax_ctree_visit_ex`.

---

## Step 3: MicrocodeContext Mutations (C Shim + Swift)

### 3.1 C Shim Additions (~30 functions)

All prefixed `idax_microcode_context_`. The `void* mctx` is the opaque `MicrocodeContext*` passed to filter callbacks.

```c
// Instruction removal
int idax_microcode_context_remove_last_emitted(void* mctx);
int idax_microcode_context_remove_at_index(void* mctx, int index);

// Noop emission
int idax_microcode_context_emit_noop(void* mctx);
int idax_microcode_context_emit_noop_with_policy(void* mctx, int policy);

// Instruction emission (IdaxMicrocodeInstruction passed by pointer)
int idax_microcode_context_emit_instruction(void* mctx, const IdaxMicrocodeInstruction* instr);
int idax_microcode_context_emit_instruction_with_policy(void* mctx,
    const IdaxMicrocodeInstruction* instr, int policy);

// Register operations
int idax_microcode_context_load_operand_register(void* mctx, int operand_index, int* out_reg);
int idax_microcode_context_load_effective_address_register(void* mctx, int operand_index, int* out_reg);
int idax_microcode_context_allocate_temporary_register(void* mctx, int byte_width, int* out_reg);
int idax_microcode_context_store_operand_register(void* mctx, int operand_index,
    int source_reg, int byte_width, int mark_udt);

// Move register
int idax_microcode_context_emit_move_register(void* mctx,
    int src, int dst, int byte_width, int mark_udt, int policy);

// Load/store memory register
int idax_microcode_context_emit_load_memory_register(void* mctx,
    int sel, int off, int dst, int byte_width, int off_byte_width, int mark_udt, int policy);
int idax_microcode_context_emit_store_memory_register(void* mctx,
    int src, int sel, int off, int byte_width, int off_byte_width, int mark_udt, int policy);

// Helper calls (multiple variants)
int idax_microcode_context_emit_helper_call(void* mctx, const char* name);
int idax_microcode_context_emit_helper_call_with_args(void* mctx, const char* name,
    const IdaxMicrocodeValue* args, size_t arg_count);
int idax_microcode_context_emit_helper_call_to_register(void* mctx, const char* name,
    const IdaxMicrocodeValue* args, size_t arg_count,
    int dst_reg, int dst_byte_width, int dst_unsigned);
int idax_microcode_context_emit_helper_call_to_operand(void* mctx, const char* name,
    const IdaxMicrocodeValue* args, size_t arg_count,
    int dst_operand_index, int dst_byte_width, int dst_unsigned);
```

### 3.2 New C Shim Types

```c
typedef enum {
    IdaxMicrocodeInsertPolicyAppend = 0,
    IdaxMicrocodeInsertPolicyPrepend = 1,
    IdaxMicrocodeInsertPolicyReplace = 2
} IdaxMicrocodeInsertPolicy;

typedef struct {
    int opcode;
    IdaxMicrocodeOperand left;
    IdaxMicrocodeOperand right;
    IdaxMicrocodeOperand destination;
    uint64_t address;
} IdaxMicrocodeInstruction;

typedef struct {
    int kind;           // register, number, memory, etc.
    int register_number;
    int64_t value;
    int byte_width;
} IdaxMicrocodeOperand;

typedef struct {
    int kind;           // MicrocodeValueKind
    int location_kind;  // MicrocodeValueLocationKind
    int64_t data;
    int byte_width;
} IdaxMicrocodeValue;
```

### 3.3 Swift Wrapper

```swift
public enum MicrocodeInsertPolicy: Int32, Sendable {
    case append = 0
    case prepend = 1
    case replace = 2
}

public struct MicrocodeInstruction: Sendable {
    public var opcode: Int32
    public var left: MicrocodeOperand
    public var right: MicrocodeOperand
    public var destination: MicrocodeOperand
    public var address: Address
}

public struct MicrocodeOperand: Sendable {
    public var kind: Int32
    public var registerNumber: Int32
    public var value: Int64
    public var byteWidth: Int32
}

public struct MicrocodeValue: Sendable {
    public var kind: Int32
    public var locationKind: Int32
    public var data: Int64
    public var byteWidth: Int32
}

extension MicrocodeContext {
    // Removal
    public func removeLastEmittedInstruction() throws(IDAError)
    public func removeInstruction(at index: Int) throws(IDAError)

    // Emission
    public func emitNoop(policy: MicrocodeInsertPolicy = .append) throws(IDAError)
    public func emitInstruction(_ instruction: MicrocodeInstruction,
                                policy: MicrocodeInsertPolicy = .append) throws(IDAError)

    // Register operations
    public func loadOperandRegister(operandIndex: Int) throws(IDAError) -> Int
    public func loadEffectiveAddressRegister(operandIndex: Int) throws(IDAError) -> Int
    public func allocateTemporaryRegister(byteWidth: Int) throws(IDAError) -> Int
    public func storeOperandRegister(operandIndex: Int, source: Int,
                                     byteWidth: Int,
                                     markUserDefinedType: Bool = false) throws(IDAError)

    // Move/load/store
    public func emitMoveRegister(source: Int, destination: Int, byteWidth: Int,
                                 markUserDefinedType: Bool = false,
                                 policy: MicrocodeInsertPolicy = .append) throws(IDAError)
    public func emitLoadMemoryRegister(segment: Int, offset: Int, destination: Int,
                                       byteWidth: Int, offsetByteWidth: Int,
                                       markUserDefinedType: Bool = false,
                                       policy: MicrocodeInsertPolicy = .append) throws(IDAError)
    public func emitStoreMemoryRegister(source: Int, segment: Int, offset: Int,
                                        byteWidth: Int, offsetByteWidth: Int,
                                        markUserDefinedType: Bool = false,
                                        policy: MicrocodeInsertPolicy = .append) throws(IDAError)

    // Helper calls
    public func emitHelperCall(_ name: String) throws(IDAError)
    public func emitHelperCall(_ name: String,
                               arguments: [MicrocodeValue]) throws(IDAError)
    public func emitHelperCall(_ name: String, arguments: [MicrocodeValue],
                               destinationRegister: Int, byteWidth: Int,
                               unsigned: Bool = true) throws(IDAError)
    public func emitHelperCall(_ name: String, arguments: [MicrocodeValue],
                               destinationOperand: Int, byteWidth: Int,
                               unsigned: Bool = true) throws(IDAError)
}
```

---

## Step 4: Processor Module (C Shim + Swift)

### 4.1 C Shim Types

```c
typedef struct {
    const char* name;
    int byte_width;
    uint32_t flags;
} IdaxRegisterInfo;

typedef struct {
    const char* name;
    uint32_t feature_flags;
} IdaxInstructionDescriptor;

typedef struct {
    const char* name;
    uint32_t flags;
    int header_count;
    const char** headers;
    const char** bad_instructions;
    int bad_instruction_count;
} IdaxAssemblerInfo;

typedef struct {
    const char* short_name;
    const char* long_name;
    int register_count;
    IdaxRegisterInfo* registers;
    int instruction_count;
    IdaxInstructionDescriptor* instructions;
    int assembler_count;
    IdaxAssemblerInfo* assemblers;
    int code_register;
    int data_register;
    int stack_register;
    int return_register;
    uint32_t flags;
} IdaxProcessorInfo;

typedef struct {
    int kind;
    size_t case_count;
    int64_t* case_values;
    uint64_t target_address;
} IdaxSwitchCase;

typedef struct {
    int kind;
    uint64_t jump_table_address;
    size_t case_count;
    IdaxSwitchCase* cases;
} IdaxSwitchDescription;
```

### 4.2 C Shim Callback Table + Registration

```c
typedef struct {
    // Required callbacks (non-NULL)
    void  (*info)(void* ctx, IdaxProcessorInfo* out);
    int   (*analyze)(void* ctx, uint64_t address, int* out_length);
    int   (*emulate)(void* ctx, uint64_t address, int* out_result);
    void  (*output_instruction)(void* ctx, uint64_t address, void* output_ctx);
    int   (*output_operand)(void* ctx, uint64_t address, int operand_index,
                            void* output_ctx, int* out_result);

    // Optional callbacks (NULL = use default behavior)
    int   (*is_call)(void* ctx, uint64_t address);
    int   (*is_return)(void* ctx, uint64_t address);
    int   (*may_be_function)(void* ctx, uint64_t address);
    int   (*is_sane_instruction)(void* ctx, uint64_t address, int no_code_refs);
    int   (*is_indirect_jump)(void* ctx, uint64_t address);
    int   (*is_basic_block_end)(void* ctx, uint64_t address, int call_stops_block);
    int   (*create_function_frame)(void* ctx, uint64_t function_start);
    int   (*adjust_function_bounds)(void* ctx, uint64_t function_start,
                                     uint64_t max_end, int suggested_result);
    int   (*analyze_function_prolog)(void* ctx, uint64_t function_start);
    int   (*calculate_stack_pointer_delta)(void* ctx, uint64_t address, int64_t* out_delta);
    int   (*get_return_address_size)(void* ctx, uint64_t function_start);
    int   (*detect_switch)(void* ctx, uint64_t address, IdaxSwitchDescription* out);
    void  (*on_new_file)(void* ctx, const char* filename);
    void  (*on_old_file)(void* ctx, const char* filename);
} IdaxProcessorCallbacks;

int idax_processor_register(const IdaxProcessorCallbacks* callbacks,
                             void* ctx, void** out_handle);
int idax_processor_unregister(void* handle);
void idax_processor_info_free(IdaxProcessorInfo* info);
void idax_switch_description_free(IdaxSwitchDescription* desc);
```

### 4.3 OutputContext C Shim (~20 functions)

```c
void idax_output_context_token(void* octx, int kind, const char* text);
void idax_output_context_append(void* octx, const char* text);
void idax_output_context_mnemonic(void* octx, const char* text);
void idax_output_context_register_name(void* octx, const char* text);
void idax_output_context_symbol(void* octx, const char* text);
void idax_output_context_keyword(void* octx, const char* text);
void idax_output_context_comment(void* octx, const char* text);
void idax_output_context_number(void* octx, const char* text);
void idax_output_context_operator_symbol(void* octx, const char* text);
void idax_output_context_punctuation(void* octx, const char* text);
void idax_output_context_whitespace(void* octx, const char* text);
void idax_output_context_string_literal(void* octx, const char* text, char quote);
void idax_output_context_immediate(void* octx, int64_t value, int radix);
void idax_output_context_address(void* octx, uint64_t address);
void idax_output_context_character(void* octx, char ch);
void idax_output_context_space(void* octx);
void idax_output_context_comma(void* octx);
void idax_output_context_clear(void* octx);
int  idax_output_context_is_empty(void* octx);
int  idax_output_context_text(void* octx, char** out_text);
```

### 4.4 Swift Types

```swift
public struct ProcessorInfo: Sendable {
    public var shortName: String
    public var longName: String
    public var registers: [RegisterInfo]
    public var instructions: [InstructionDescriptor]
    public var assemblers: [AssemblerInfo]
    public var codeRegister: Int
    public var dataRegister: Int
    public var stackRegister: Int
    public var returnRegister: Int
    public var flags: UInt32
}

public struct RegisterInfo: Sendable {
    public var name: String
    public var byteWidth: Int
    public var flags: UInt32
}

public struct InstructionDescriptor: Sendable {
    public var name: String
    public var featureFlags: UInt32
}

public struct AssemblerInfo: Sendable {
    public var name: String
    public var flags: UInt32
    public var headers: [String]
    public var badInstructions: [String]
}

public struct SwitchCase: Sendable {
    public var values: [Int64]
    public var targetAddress: Address
}

public struct SwitchDescription: Sendable {
    public var kind: SwitchTableKind
    public var jumpTableAddress: Address
    public var cases: [SwitchCase]
}

public enum SwitchTableKind: Int32, Sendable {
    case flat = 0
    case indexed = 1
    case sparse = 2
}

public enum EmulateResult: Int32, Sendable {
    case ok = 0
    case stop = 1
    case error = 2
}

public enum OutputOperandResult: Int32, Sendable {
    case ok = 0
    case skip = 1
    case error = 2
}
```

### 4.5 Swift Protocol + OutputContext

```swift
public protocol ProcessorModule: AnyObject {
    // Required
    var info: ProcessorInfo { get }
    func analyze(at address: Address) throws(IDAError) -> Int
    func emulate(at address: Address) -> EmulateResult
    func outputInstruction(at address: Address, to context: borrowing OutputContext)
    func outputOperand(at address: Address, operand: Int,
                       to context: borrowing OutputContext) -> OutputOperandResult
}

extension ProcessorModule {
    // Optional — default implementations return negative / false / no-op
    func isCall(at address: Address) -> Bool { false }
    func isReturn(at address: Address) -> Bool { false }
    func mayBeFunction(at address: Address) -> Bool { false }
    func isSaneInstruction(at address: Address, noCodeReferences: Bool) -> Bool { true }
    func isIndirectJump(at address: Address) -> Bool { false }
    func isBasicBlockEnd(at address: Address, callStopsBlock: Bool) -> Bool { false }
    func createFunctionFrame(at functionStart: Address) -> Bool { false }
    func adjustFunctionBounds(at functionStart: Address,
                              maxEnd: Address, suggestedResult: Int) -> Int { suggestedResult }
    func analyzeFunctionProlog(at functionStart: Address) -> Int { 0 }
    func calculateStackPointerDelta(at address: Address) -> Int64? { nil }
    func returnAddressSize(at functionStart: Address) -> Int { 0 }
    func detectSwitch(at address: Address) -> SwitchDescription? { nil }
    func onNewFile(_ filename: String) {}
    func onOldFile(_ filename: String) {}
}

public struct OutputContext: ~Copyable {
    private let handle: UnsafeMutableRawPointer

    public func mnemonic(_ text: String) { ... }
    public func registerName(_ text: String) { ... }
    public func symbol(_ text: String) { ... }
    public func keyword(_ text: String) { ... }
    public func comment(_ text: String) { ... }
    public func number(_ text: String) { ... }
    public func operatorSymbol(_ text: String) { ... }
    public func punctuation(_ text: String) { ... }
    public func whitespace(_ text: String = " ") { ... }
    public func stringLiteral(_ text: String, quote: Character = "\"") { ... }
    public func immediate(_ value: Int64, radix: Int = 16) { ... }
    public func address(_ address: Address) { ... }
    public func character(_ ch: Character) { ... }
    public func space() { ... }
    public func comma() { ... }
    public func clear() { ... }
    public var isEmpty: Bool { ... }
    public var text: String { get throws(IDAError) }
}

public struct ProcessorRegistration: ~Copyable, @unchecked Sendable {
    public consuming func unregister() { ... }
    deinit { /* auto unregister */ }
}

// Factory
extension ProcessorModule {
    public static func register(_ module: some ProcessorModule) throws(IDAError) -> ProcessorRegistration
}
```

Implementation: A private `ProcessorBox` class (similar to `GraphCallbackBox`, `MicrocodeFilterBox`) bridges Swift protocol calls through C function pointer trampolines.

---

## Step 5: Database + Core Enhancements (C Shim + Swift)

### 5.1 C Shim Additions

```c
typedef struct {
    int auto_load_plugins;       // default 1
    int load_previous_database;  // default 1
    const char* screen_palette;  // NULL = default
} IdaxRuntimeOptions;

int idax_database_init_with_options(const IdaxRuntimeOptions* options);
int idax_database_open_with_intent(const char* path, int intent, int mode);
```

### 5.2 Swift Types + Extensions

```swift
public struct RuntimeOptions: Sendable {
    public var autoLoadPlugins: Bool = true
    public var loadPreviousDatabase: Bool = true
    public var screenPalette: String? = nil

    public init() {}
}

public enum OpenMode: Int32, Sendable {
    case analyze = 0
    case skipAnalysis = 1
}

public enum LoadIntent: Int32, Sendable {
    case autoDetect = 0
    case binary = 1
    case nonBinary = 2
}

extension Database {
    public static func initialize(options: RuntimeOptions) throws(IDAError) { ... }

    public static func open(_ path: String, intent: LoadIntent = .autoDetect,
                            mode: OpenMode = .analyze) throws(IDAError) { ... }
}

// Core option types (for future API extensions)
public struct OperationOptions: Sendable {
    public var strictValidation: Bool = false
    public var allowPartialResults: Bool = false
    public var cancelOnUserBreak: Bool = false
    public var quiet: Bool = false

    public init() {}
}

public struct RangeOptions: Sendable {
    public var start: Address
    public var end: Address
    public var inclusiveEnd: Bool = false
}

public struct WaitOptions: Sendable {
    public var timeoutMilliseconds: UInt32 = 0
    public var pollIntervalMilliseconds: UInt32 = 100
}
```

---

## File Change Summary

| Step | Files Modified | Files Created |
|------|---------------|---------------|
| 1 | Types.swift, Lines.swift, Database.swift, Graph.swift, Segment.swift, Diagnostics.swift, Xref.swift, Data.swift, Decompiler.swift, UI.swift, UnitTests.swift | — |
| 2 | idax_shim.h (×2), idax_shim.cpp, Decompiler.swift | — |
| 3 | idax_shim.h (×2), idax_shim.cpp, Decompiler.swift | — |
| 4 | idax_shim.h (×2), idax_shim.cpp | Processor.swift |
| 5 | idax_shim.h (×2), idax_shim.cpp, Database.swift | — |

## Testing Strategy

- **Step 1:** `swift test` — unit tests for all new enums (raw values, unknown returns nil), convenience function logic, xref predicates.
- **Steps 2–5:** Unit tests for new type construction. Integration tests require IDADIR and are not run in CI. C shim functions are tested indirectly through Swift wrappers.

## Risks

- **ProcessorID raw values:** Must be verified against `include/ida/database.hpp` at implementation time. If the C++ enum uses non-sequential values, the Swift enum must match exactly.
- **MicrocodeContext mutations:** These operate on live decompiler state. Incorrect use can corrupt the microcode. The Swift API should document this clearly.
- **Processor module:** The most complex addition. The callback trampoline pattern is proven (used by Graph, Plugin, Event) but Processor has the most callbacks (~20 optional).
- **Breaking change:** Changing `callingConvention: Int` to `CallingConvention` and `colorString(_:color: UInt8)` to `Color` are source-breaking. This is acceptable on the current feature branch before any public release.
