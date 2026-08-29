internal import CIDAX

/// Width and placement of an offset reference.
public enum OffsetReferenceKind: Int32, Sendable {
    case offset8 = 0
    case offset16 = 1
    case offset32 = 2
    case offset64 = 3
    case low8 = 4
    case low16 = 5
    case low32 = 6
    case high8 = 7
    case high16 = 8
    case high32 = 9
    /// A processor-supplied format, named by ``OffsetReferenceType/customName``.
    case custom = 10
}

/// Whether a rendered expression is a bare name or something composite.
public enum ExpressionComplexity: Int32, Sendable {
    case simple = 0
    case complex = 1
}

/// A reference format: one of the standard kinds, or a named custom one.
public struct OffsetReferenceType: Sendable, Equatable {
    public let kind: OffsetReferenceKind
    /// Empty for every standard kind; only ``OffsetReferenceKind/custom`` names one.
    public let customName: String

    public init(kind: OffsetReferenceKind, customName: String = "") {
        self.kind = kind
        self.customName = customName
    }

    init(raw: IdaxOffsetReferenceType) {
        self.kind = OffsetReferenceKind(rawValue: raw.kind) ?? .offset32
        self.customName = borrowCString(raw.custom_name)
    }
}

/// A reference format together with how IDA describes it.
public struct OffsetReferenceTypeDescriptor: Sendable {
    public let type: OffsetReferenceType
    public let name: String
    public let description: String
    /// Whether this format can be applied without naming a target.
    public let isTargetOptional: Bool

    init(raw: IdaxOffsetReferenceTypeDescriptor) {
        self.type = OffsetReferenceType(raw: raw.type)
        self.name = borrowCString(raw.name)
        self.description = borrowCString(raw.description)
        self.isTargetOptional = raw.target_optional != 0
    }
}

/// Everything that describes one offset reference.
///
/// The same shape is both read from and written to IDA. Most fields are the
/// individual flag bits the SDK packs into `refinfo_t`, given names here so a
/// caller never assembles a bitmask.
public struct OffsetReferenceInfo: Sendable {
    public var kind: OffsetReferenceKind
    public var customName: String
    public var target: Address?
    public var base: Address?
    public var targetDelta: Int64
    public var isRelativeVirtualAddress: Bool
    public var allowsPastEnd: Bool
    public var suppressesBaseReference: Bool
    public var subtractsOperand: Bool
    public var signExtendsOperand: Bool
    public var acceptsZero: Bool
    public var rejectsAllOnes: Bool
    public var isSelfRelative: Bool
    public var ignoresFixup: Bool

    public init(
        kind: OffsetReferenceKind,
        customName: String = "",
        target: Address? = nil,
        base: Address? = nil,
        targetDelta: Int64 = 0,
        isRelativeVirtualAddress: Bool = false,
        allowsPastEnd: Bool = false,
        suppressesBaseReference: Bool = false,
        subtractsOperand: Bool = false,
        signExtendsOperand: Bool = false,
        acceptsZero: Bool = false,
        rejectsAllOnes: Bool = false,
        isSelfRelative: Bool = false,
        ignoresFixup: Bool = false
    ) {
        self.kind = kind
        self.customName = customName
        self.target = target
        self.base = base
        self.targetDelta = targetDelta
        self.isRelativeVirtualAddress = isRelativeVirtualAddress
        self.allowsPastEnd = allowsPastEnd
        self.suppressesBaseReference = suppressesBaseReference
        self.subtractsOperand = subtractsOperand
        self.signExtendsOperand = signExtendsOperand
        self.acceptsZero = acceptsZero
        self.rejectsAllOnes = rejectsAllOnes
        self.isSelfRelative = isSelfRelative
        self.ignoresFixup = ignoresFixup
    }

    init(raw: IdaxOffsetReferenceInfo) {
        self.kind = OffsetReferenceKind(rawValue: raw.kind) ?? .offset32
        self.customName = borrowCString(raw.custom_name)
        self.target = raw.has_target != 0 ? raw.target : nil
        self.base = raw.has_base != 0 ? raw.base : nil
        self.targetDelta = raw.target_delta
        self.isRelativeVirtualAddress = raw.relative_virtual_address != 0
        self.allowsPastEnd = raw.allow_past_end != 0
        self.suppressesBaseReference = raw.suppress_base_reference != 0
        self.subtractsOperand = raw.subtract_operand != 0
        self.signExtendsOperand = raw.sign_extend_operand != 0
        self.acceptsZero = raw.accept_zero != 0
        self.rejectsAllOnes = raw.reject_all_ones != 0
        self.isSelfRelative = raw.self_relative != 0
        self.ignoresFixup = raw.ignore_fixup != 0
    }

    /// Borrow this value as the C input struct for the duration of `body`.
    func withRawInput<CallResult>(
        _ body: (UnsafePointer<IdaxOffsetReferenceInfoInput>) -> CallResult
    ) -> CallResult {
        customName.withCString { customNamePointer in
            var raw = IdaxOffsetReferenceInfoInput()
            raw.kind = kind.rawValue
            raw.custom_name = customNamePointer
            raw.has_target = target == nil ? 0 : 1
            raw.target = target ?? 0
            raw.has_base = base == nil ? 0 : 1
            raw.base = base ?? 0
            raw.target_delta = targetDelta
            raw.relative_virtual_address = isRelativeVirtualAddress ? 1 : 0
            raw.allow_past_end = allowsPastEnd ? 1 : 0
            raw.suppress_base_reference = suppressesBaseReference ? 1 : 0
            raw.subtract_operand = subtractsOperand ? 1 : 0
            raw.sign_extend_operand = signExtendsOperand ? 1 : 0
            raw.accept_zero = acceptsZero ? 1 : 0
            raw.reject_all_ones = rejectsAllOnes ? 1 : 0
            raw.self_relative = isSelfRelative ? 1 : 0
            raw.ignore_fixup = ignoresFixup ? 1 : 0
            return withUnsafePointer(to: &raw) { body($0) }
        }
    }
}

/// A reference expression as IDA would print it.
public struct RenderedExpression: Sendable {
    public let text: String
    public let complexity: ExpressionComplexity

    init(raw: IdaxOffsetRenderedExpression) {
        self.text = borrowCString(raw.text)
        self.complexity = ExpressionComplexity(rawValue: raw.complexity) ?? .simple
    }
}

/// What a reference resolves to, without applying it.
public struct OffsetReferenceCalculation: Sendable {
    public let target: Address?
    public let base: Address?

    init(raw: IdaxOffsetReferenceCalculation) {
        self.target = raw.has_target != 0 ? raw.target : nil
        self.base = raw.has_base != 0 ? raw.base : nil
    }
}

/// Offset references — the metadata that turns a numeric operand into an
/// address expression.
///
/// Operands are addressed by index plus an `isOuter` flag, matching the SDK's
/// distinction between the outer operand and the inner one of a composite.
public enum Offset {

    /// Every reference format this processor offers, including custom ones.
    public static func referenceTypes() throws(IDAError) -> [OffsetReferenceTypeDescriptor] {
        var pointer: UnsafeMutablePointer<IdaxOffsetReferenceTypeDescriptor>? = nil
        var count: Int = 0
        try checkStatus(
            idax_offset_reference_types(&pointer, &count),
            "offset.referenceTypes"
        )
        defer { idax_offset_reference_types_free(pointer, count) }
        guard let pointer, count > 0 else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count)
            .map(OffsetReferenceTypeDescriptor.init(raw:))
    }

    /// The format IDA would choose at `address`.
    public static func defaultReferenceType(
        at address: Address
    ) throws(IDAError) -> OffsetReferenceType {
        var raw = IdaxOffsetReferenceType()
        try checkStatus(
            idax_offset_default_reference_type(address, &raw),
            "offset.defaultReferenceType"
        )
        defer { idax_offset_reference_type_free(&raw) }
        return OffsetReferenceType(raw: raw)
    }

    /// The reference stored on an operand, or `nil` when it carries none.
    public static func referenceInfo(
        at address: Address,
        operandIndex: Int,
        isOuter: Bool = false
    ) throws(IDAError) -> OffsetReferenceInfo? {
        var raw = IdaxOffsetReferenceInfo()
        var hasInfo: Int32 = 0
        try checkStatus(
            idax_offset_reference_info(
                address, operandIndex, isOuter ? 1 : 0, &raw, &hasInfo
            ),
            "offset.referenceInfo"
        )
        guard hasInfo != 0 else { return nil }
        defer { idax_offset_reference_info_free(&raw) }
        return OffsetReferenceInfo(raw: raw)
    }

    /// Stores a reference on an operand.
    public static func applyReference(
        _ info: OffsetReferenceInfo,
        at address: Address,
        operandIndex: Int,
        isOuter: Bool = false
    ) throws(IDAError) {
        try checkStatus(
            info.withRawInput {
                idax_offset_apply_reference(address, operandIndex, isOuter ? 1 : 0, $0)
            },
            "offset.applyReference"
        )
    }

    /// Removes the reference stored on an operand.
    ///
    /// - Returns: whether there was one to remove.
    @discardableResult
    public static func removeReference(
        at address: Address,
        operandIndex: Int,
        isOuter: Bool = false
    ) throws(IDAError) -> Bool {
        try withOutput("offset.removeReference", Int32(0)) {
            idax_offset_remove_reference(address, operandIndex, isOuter ? 1 : 0, $0)
        } != 0
    }

    // MARK: - Rendering

    /// Renders the reference already stored on an operand.
    public static func renderStoredExpression(
        at address: Address,
        operandIndex: Int,
        isOuter: Bool = false,
        from: Address,
        operandValue: Int64,
        appendZeroField: Bool = false,
        avoidDummyNames: Bool = false
    ) throws(IDAError) -> RenderedExpression {
        var raw = IdaxOffsetRenderedExpression()
        try checkStatus(
            idax_offset_render_stored_expression(
                address, operandIndex, isOuter ? 1 : 0,
                from, operandValue,
                appendZeroField ? 1 : 0, avoidDummyNames ? 1 : 0,
                &raw
            ),
            "offset.renderStoredExpression"
        )
        defer { idax_offset_rendered_expression_free(&raw) }
        return RenderedExpression(raw: raw)
    }

    /// Renders a reference without storing it, to preview what applying it
    /// would produce.
    public static func renderExpression(
        _ info: OffsetReferenceInfo,
        at address: Address,
        operandIndex: Int,
        isOuter: Bool = false,
        from: Address,
        operandValue: Int64,
        appendZeroField: Bool = false,
        avoidDummyNames: Bool = false
    ) throws(IDAError) -> RenderedExpression {
        var raw = IdaxOffsetRenderedExpression()
        try checkStatus(
            info.withRawInput {
                idax_offset_render_expression(
                    address, operandIndex, isOuter ? 1 : 0, $0,
                    from, operandValue,
                    appendZeroField ? 1 : 0, avoidDummyNames ? 1 : 0,
                    &raw
                )
            },
            "offset.renderExpression"
        )
        defer { idax_offset_rendered_expression_free(&raw) }
        return RenderedExpression(raw: raw)
    }

    // MARK: - Calculation

    /// The address a 32-bit offset at `address` would point at, when there is a
    /// plausible one.
    public static func possibleOffset32Target(
        at address: Address
    ) throws(IDAError) -> Address? {
        var out: UInt64 = 0
        var hasValue: Int32 = 0
        try checkStatus(
            idax_offset_possible_offset32_target(address, &out, &hasValue),
            "offset.possibleOffset32Target"
        )
        return hasValue != 0 ? out : nil
    }

    /// The base an operand's stored reference resolves against.
    public static func calculateOffsetBase(
        at address: Address,
        operandIndex: Int,
        isOuter: Bool = false
    ) throws(IDAError) -> Address? {
        var out: UInt64 = 0
        var hasValue: Int32 = 0
        try checkStatus(
            idax_offset_calculate_offset_base(
                address, operandIndex, isOuter ? 1 : 0, &out, &hasValue
            ),
            "offset.calculateOffsetBase"
        )
        return hasValue != 0 ? out : nil
    }

    /// The base IDA would guess for `operandValue` at `address`.
    public static func probableBase(
        at address: Address,
        operandValue: Address
    ) throws(IDAError) -> Address? {
        var out: UInt64 = 0
        var hasValue: Int32 = 0
        try checkStatus(
            idax_offset_probable_base(address, operandValue, &out, &hasValue),
            "offset.probableBase"
        )
        return hasValue != 0 ? out : nil
    }

    /// Resolves a reference without applying it.
    public static func calculateReference(
        _ info: OffsetReferenceInfo,
        from: Address,
        operandValue: Int64
    ) throws(IDAError) -> OffsetReferenceCalculation {
        var raw = IdaxOffsetReferenceCalculation()
        try checkStatus(
            info.withRawInput {
                idax_offset_calculate_reference(from, $0, operandValue, &raw)
            },
            "offset.calculateReference"
        )
        return OffsetReferenceCalculation(raw: raw)
    }

    /// The base value that makes `base` reach `target`.
    public static func calculateBaseValue(
        target: Address,
        base: Address
    ) throws(IDAError) -> Address? {
        var out: UInt64 = 0
        var hasValue: Int32 = 0
        try checkStatus(
            idax_offset_calculate_base_value(target, base, &out, &hasValue),
            "offset.calculateBaseValue"
        )
        return hasValue != 0 ? out : nil
    }

    /// Creates the data references an operand's offset implies.
    ///
    /// - Returns: how many references were added.
    @discardableResult
    public static func addOperandDataReferences(
        at instructionAddress: Address,
        operandIndex: Int,
        isOuter: Bool = false,
        dataType: Int32
    ) throws(IDAError) -> Address {
        try withOutput("offset.addOperandDataReferences", UInt64(0)) {
            idax_offset_add_operand_data_references(
                instructionAddress, operandIndex, isOuter ? 1 : 0, dataType, $0
            )
        }
    }
}
