import CIDA

/// Operand type classification.
public enum OperandType: Int32, Sendable {
    case void_ = 0, register, memory, phrase
    case displacement, immediate, far, near
}

/// Decoded instruction operand.
public struct Operand: Sendable {
    public let index: Int
    public let operandType: OperandType
    public let registerID: UInt16
    public let registerName: String
    public let value: UInt64
    public let targetAddress: Address
    public let byteWidth: Int

    public var isImmediate: Bool { operandType == .immediate }
    public var isRegister: Bool { operandType == .register }
    public var isMemory: Bool { operandType == .memory }
}

/// Decoded instruction snapshot.
public struct Instruction: Sendable {
    public let address: Address
    public let size: AddressSize
    public let opcode: UInt16
    public let mnemonic: String
    public let operands: [Operand]

    public var operandCount: Int { operands.count }

    // MARK: - Queries

    public static func decode(at address: Address) throws(IDAError) -> Instruction {
        var raw = IdaxInstruction()
        try checkStatus(idax_instruction_decode(address, &raw), "instruction.decode")
        defer { idax_instruction_free(&raw) }
        return Instruction(raw: raw)
    }

    public static func text(at address: Address) throws(IDAError) -> String {
        try withStringOutput("instruction.text") { idax_instruction_text(address, $0) }
    }

    // MARK: - Predicates

    public static func isCall(_ address: Address) -> Bool {
        idax_instruction_is_call(address) != 0
    }

    public static func isReturn(_ address: Address) -> Bool {
        idax_instruction_is_return(address) != 0
    }

    public static func isJump(_ address: Address) -> Bool {
        idax_instruction_is_jump(address) != 0
    }

    public static func isConditionalJump(_ address: Address) -> Bool {
        idax_instruction_is_conditional_jump(address) != 0
    }

    public static func hasFallThrough(_ address: Address) -> Bool {
        idax_instruction_has_fall_through(address) != 0
    }

    // MARK: - Xref conveniences

    public static func codeRefsFrom(_ address: Address) throws(IDAError) -> [Address] {
        try withAddressArrayOutput("instruction.codeRefsFrom") { idax_instruction_code_refs_from(address, $0, $1) }
    }

    public static func dataRefsFrom(_ address: Address) throws(IDAError) -> [Address] {
        try withAddressArrayOutput("instruction.dataRefsFrom") { idax_instruction_data_refs_from(address, $0, $1) }
    }

    public static func callTargets(_ address: Address) throws(IDAError) -> [Address] {
        try withAddressArrayOutput("instruction.callTargets") { idax_instruction_call_targets(address, $0, $1) }
    }

    public static func jumpTargets(_ address: Address) throws(IDAError) -> [Address] {
        try withAddressArrayOutput("instruction.jumpTargets") { idax_instruction_jump_targets(address, $0, $1) }
    }

    // MARK: - Operand display

    public static func setOperandHex(_ address: Address, operand n: Int) throws(IDAError) {
        try checkStatus(idax_instruction_set_operand_hex(address, Int32(n)), "instruction.setOperandHex")
    }

    public static func setOperandDecimal(_ address: Address, operand n: Int) throws(IDAError) {
        try checkStatus(idax_instruction_set_operand_decimal(address, Int32(n)), "instruction.setOperandDecimal")
    }

    // MARK: - Internal

    init(raw: IdaxInstruction) {
        self.address = raw.address
        self.size = raw.size
        self.opcode = raw.opcode
        self.mnemonic = takeCString(raw.mnemonic)

        var ops: [Operand] = []
        if let ptr = raw.operands, raw.operand_count > 0 {
            let buf = UnsafeBufferPointer(start: ptr, count: raw.operand_count)
            ops = buf.map { o in
                Operand(
                    index: Int(o.index),
                    operandType: OperandType(rawValue: Int32(o.type)) ?? .void_,
                    registerID: o.register_id,
                    registerName: takeCString(o.register_name),
                    value: o.value,
                    targetAddress: o.target_address,
                    byteWidth: Int(o.byte_width)
                )
            }
        }
        self.operands = ops
    }
}
