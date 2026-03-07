import Testing
@testable import IDA

// MARK: - Error Model

@Suite("IDA Error Model")
struct ErrorModelTests {
    @Test func errorCategoryDescription() {
        #expect(IDAErrorCategory.validation.description == "Validation")
        #expect(IDAErrorCategory.notFound.description == "NotFound")
        #expect(IDAErrorCategory.conflict.description == "Conflict")
        #expect(IDAErrorCategory.unsupported.description == "Unsupported")
        #expect(IDAErrorCategory.sdkFailure.description == "SdkFailure")
        #expect(IDAErrorCategory.internal.description == "Internal")
    }

    @Test func errorDescription() {
        let err = IDAError(category: .notFound, code: 42, message: "symbol missing")
        #expect(err.description == "[NotFound] symbol missing")
    }

    @Test func errorCategoryRawValues() {
        #expect(IDAErrorCategory.validation.rawValue == 1)
        #expect(IDAErrorCategory.notFound.rawValue == 2)
        #expect(IDAErrorCategory.conflict.rawValue == 3)
        #expect(IDAErrorCategory.unsupported.rawValue == 4)
        #expect(IDAErrorCategory.sdkFailure.rawValue == 5)
        #expect(IDAErrorCategory.internal.rawValue == 6)
    }

    @Test func unknownCategoryRawValueReturnsNil() {
        #expect(IDAErrorCategory(rawValue: 0) == nil)
        #expect(IDAErrorCategory(rawValue: 99) == nil)
    }
}

@Suite("IDA Error Helpers")
struct ErrorHelperTests {
    @Test func consumeLastErrorUsesFallbackCategory() {
        let err = consumeLastError(fallback: "test fallback")
        #expect(err.category == .internal)
    }

    @Test func checkStatusSuccessDoesNotThrow() throws {
        try checkStatus(0, "should not throw")
    }

    @Test func checkStatusFailureThrows() {
        #expect(throws: IDAError.self) {
            try checkStatus(-1, "expected failure")
        }
    }
}

// MARK: - Address Types

@Suite("IDA Address Types")
struct AddressTypeTests {
    @Test func badAddressIsSentinel() {
        #expect(badAddress == UInt64.max)
    }

    @Test func addressTypealiasesAreCorrectWidth() {
        let addr: Address = 0x00400000
        #expect(addr == 4194304)

        let delta: AddressDelta = -128
        #expect(delta < 0)

        let size: AddressSize = 0x1000
        #expect(size == 4096)
    }
}

// MARK: - Segment Types

@Suite("IDA SegmentType")
struct SegmentTypeTests {
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

@Suite("IDA Permissions")
struct PermissionsTests {
    @Test func equality() {
        let a = Permissions(read: true, write: false, execute: true)
        let b = Permissions(read: true, write: false, execute: true)
        let c = Permissions(read: false, write: true, execute: false)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func allFalse() {
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

// MARK: - Operand Types

@Suite("IDA OperandType")
struct OperandTypeTests {
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

    @Test func unknownRawValueReturnsNil() {
        #expect(OperandType(rawValue: 99) == nil)
    }
}

@Suite("IDA Operand predicates")
struct OperandPredicateTests {
    @Test func isImmediateWhenTypeIsImmediate() {
        let op = Operand(
            index: 0, operandType: .immediate, registerID: 0,
            registerName: "", registerCategory: 0, value: 42,
            targetAddress: 0, byteWidth: 4
        )
        #expect(op.isImmediate)
        #expect(!op.isRegister)
        #expect(!op.isMemory)
    }

    @Test func isRegisterWhenTypeIsRegister() {
        let op = Operand(
            index: 0, operandType: .register, registerID: 1,
            registerName: "rax", registerCategory: 0, value: 0,
            targetAddress: 0, byteWidth: 8
        )
        #expect(op.isRegister)
        #expect(!op.isImmediate)
    }
}

// MARK: - Xref Types

@Suite("IDA ReferenceType")
struct ReferenceTypeTests {
    @Test func rawValues() {
        #expect(ReferenceType.unknown.rawValue == 0)
        #expect(ReferenceType.flow.rawValue == 1)
        #expect(ReferenceType.callNear.rawValue == 2)
        #expect(ReferenceType.callFar.rawValue == 3)
        #expect(ReferenceType.jumpNear.rawValue == 4)
        #expect(ReferenceType.jumpFar.rawValue == 5)
        #expect(ReferenceType.offset.rawValue == 6)
        #expect(ReferenceType.read.rawValue == 7)
        #expect(ReferenceType.write.rawValue == 8)
        #expect(ReferenceType.text.rawValue == 9)
        #expect(ReferenceType.informational.rawValue == 10)
    }

    @Test func unknownRawValueReturnsNil() {
        #expect(ReferenceType(rawValue: 99) == nil)
    }
}

@Suite("IDA CodeXrefType")
struct CodeXrefTypeTests {
    @Test func rawValues() {
        #expect(CodeXrefType.callFar.rawValue == 0)
        #expect(CodeXrefType.callNear.rawValue == 1)
        #expect(CodeXrefType.jumpFar.rawValue == 2)
        #expect(CodeXrefType.jumpNear.rawValue == 3)
        #expect(CodeXrefType.flow.rawValue == 4)
    }
}

@Suite("IDA DataXrefType")
struct DataXrefTypeTests {
    @Test func rawValues() {
        #expect(DataXrefType.offset.rawValue == 0)
        #expect(DataXrefType.write.rawValue == 1)
        #expect(DataXrefType.read.rawValue == 2)
        #expect(DataXrefType.text.rawValue == 3)
        #expect(DataXrefType.informational.rawValue == 4)
    }
}

// MARK: - Fixup Types

@Suite("IDA FixupType")
struct FixupTypeTests {
    @Test func basicRawValues() {
        #expect(FixupType.off8.rawValue == 0)
        #expect(FixupType.off16.rawValue == 1)
        #expect(FixupType.seg16.rawValue == 2)
        #expect(FixupType.ptr16.rawValue == 3)
        #expect(FixupType.off32.rawValue == 4)
        #expect(FixupType.ptr32.rawValue == 5)
        #expect(FixupType.off64.rawValue == 10)
        #expect(FixupType.custom.rawValue == 14)
    }

    @Test func unknownRawValueReturnsNil() {
        #expect(FixupType(rawValue: 99) == nil)
    }
}

// MARK: - Name Types

@Suite("IDA DemangledForm")
struct DemangledFormTests {
    @Test func rawValues() {
        #expect(DemangledForm.short.rawValue == 0)
        #expect(DemangledForm.long.rawValue == 1)
        #expect(DemangledForm.typeOnly.rawValue == 2)
    }
}

// MARK: - Decompiler Types

@Suite("IDA VariableStorage")
struct VariableStorageTests {
    @Test func rawValues() {
        #expect(VariableStorage.unknown.rawValue == 0)
        #expect(VariableStorage.register.rawValue == 1)
        #expect(VariableStorage.stack.rawValue == 2)
    }

    @Test func unknownRawValueReturnsNil() {
        #expect(VariableStorage(rawValue: 99) == nil)
    }
}

// MARK: - Value Type Construction

@Suite("IDA Chunk")
struct ChunkTests {
    @Test func basicConstruction() {
        let c = Chunk(start: 0x1000, end: 0x2000, isTail: false, owner: 0x1000)
        #expect(c.start == 0x1000)
        #expect(c.end == 0x2000)
        #expect(!c.isTail)
        #expect(c.owner == 0x1000)
    }

    @Test func tailChunk() {
        let c = Chunk(start: 0x3000, end: 0x3100, isTail: true, owner: 0x1000)
        #expect(c.isTail)
        #expect(c.owner == 0x1000)
    }
}

@Suite("IDA FrameVariable")
struct FrameVariableTests {
    @Test func basicConstruction() {
        let fv = FrameVariable(
            name: "local_0", byteOffset: 0, byteSize: 8,
            comment: "", isSpecial: false
        )
        #expect(fv.name == "local_0")
        #expect(fv.byteSize == 8)
        #expect(!fv.isSpecial)
    }

    @Test func specialVariable() {
        let fv = FrameVariable(
            name: "__return_address", byteOffset: 16, byteSize: 8,
            comment: "return addr", isSpecial: true
        )
        #expect(fv.isSpecial)
        #expect(fv.comment == "return addr")
    }
}

@Suite("IDA LocalVariable")
struct LocalVariableTests {
    @Test func basicConstruction() {
        let lv = LocalVariable(
            name: "result", typeName: "int", isArgument: false,
            width: 4, hasUserName: true, storage: .stack, comment: ""
        )
        #expect(lv.name == "result")
        #expect(lv.storage == .stack)
        #expect(!lv.isArgument)
        #expect(lv.hasUserName)
    }

    @Test func argumentVariable() {
        let lv = LocalVariable(
            name: "argc", typeName: "int", isArgument: true,
            width: 4, hasUserName: false, storage: .register, comment: ""
        )
        #expect(lv.isArgument)
        #expect(lv.storage == .register)
    }
}
