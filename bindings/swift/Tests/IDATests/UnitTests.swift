import Testing
@testable import IDA

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
}

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

@Suite("IDA Segment Types")
struct SegmentTypeTests {
    @Test func segmentTypeRawValues() {
        #expect(SegmentType.normal.rawValue == 0)
        #expect(SegmentType.code.rawValue == 2)
        #expect(SegmentType.data.rawValue == 3)
        #expect(SegmentType.bss.rawValue == 4)
    }

    @Test func permissionsEquality() {
        let a = Permissions(read: true, write: false, execute: true)
        let b = Permissions(read: true, write: false, execute: true)
        let c = Permissions(read: false, write: true, execute: false)
        #expect(a == b)
        #expect(a != c)
    }
}

@Suite("IDA OperandType")
struct OperandTypeTests {
    @Test func operandTypeRawValues() {
        #expect(OperandType.void_.rawValue == 0)
        #expect(OperandType.register.rawValue == 1)
        #expect(OperandType.immediate.rawValue == 5)
    }
}
