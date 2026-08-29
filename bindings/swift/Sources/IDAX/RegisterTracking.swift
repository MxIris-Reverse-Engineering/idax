internal import CIDAX

/// Why a register-tracking query stopped where it did.
///
/// Only ``constant`` and ``stackPointerDelta`` carry a usable value; the rest
/// explain the absence, which is often what a caller actually needs to know.
public enum RegisterTrackingState: Int32, Sendable {
    case undefined = 0
    case deadEnd = 1
    case aborted = 2
    case badInstruction = 3
    case unknownInstruction = 4
    case functionInput = 5
    case loopVariant = 6
    case incompatibleValues = 7
    case tooManyReferences = 8
    case tooManyValues = 9
    case constant = 10
    case stackPointerDelta = 11
}

/// Whether a reference was added or removed.
public enum ReferenceMutation: Int32, Sendable {
    case added = 0
    case removed = 1
}

/// Where a candidate value came from.
public struct RegisterValueOrigin: Sendable {
    public let address: Address
    public let instructionCode: UInt16
    public let isShortInstruction: Bool
    public let isProgramCounterBased: Bool
    public let isGlobalOffsetTableLike: Bool

    init(raw: IdaxRegisterValueOrigin) {
        self.address = raw.address
        self.instructionCode = raw.instruction_code
        self.isShortInstruction = raw.short_instruction != 0
        self.isProgramCounterBased = raw.program_counter_based != 0
        self.isGlobalOffsetTableLike = raw.global_offset_table_like != 0
    }
}

/// One possible value for the register at the queried address.
///
/// A candidate carries either a constant or a stack-pointer delta, never both.
public struct RegisterValueCandidate: Sendable {
    public let constant: UInt64?
    public let stackPointerDelta: Int64?
    public let origin: RegisterValueOrigin

    init(raw: IdaxRegisterValueCandidate) {
        self.constant = raw.has_constant != 0 ? raw.constant : nil
        self.stackPointerDelta =
            raw.has_stack_pointer_delta != 0 ? raw.stack_pointer_delta : nil
        self.origin = RegisterValueOrigin(raw: raw.origin)
    }
}

/// The result of tracking a register backwards from an address.
public struct TrackedRegisterValue: Sendable {
    public let state: RegisterTrackingState
    public let candidates: [RegisterValueCandidate]
    /// Where the search gave up, when it did.
    public let cause: RegisterValueOrigin?
    /// The depth at which the search aborted, when it did.
    public let abortingDepth: Int32?
    public let description: String

    init(raw: IdaxTrackedRegisterValue) {
        self.state = RegisterTrackingState(rawValue: raw.state) ?? .undefined
        if let candidates = raw.candidates, raw.candidate_count > 0 {
            self.candidates = UnsafeBufferPointer(
                start: candidates, count: raw.candidate_count
            ).map(RegisterValueCandidate.init(raw:))
        } else {
            self.candidates = []
        }
        self.cause = raw.has_cause != 0 ? RegisterValueOrigin(raw: raw.cause) : nil
        self.abortingDepth = raw.has_aborting_depth != 0 ? raw.aborting_depth : nil
        self.description = borrowCString(raw.description)
    }
}

/// The result of asking which of two registers has a usable value.
public struct NearestRegisterValue: Sendable {
    /// 0 for the first register, 1 for the second.
    public let selectedIndex: Int
    public let registerName: String
    public let value: TrackedRegisterValue

    init(raw: IdaxNearestRegisterValue) {
        self.selectedIndex = raw.selected_index
        self.registerName = borrowCString(raw.register_name)
        self.value = TrackedRegisterValue(raw: raw.value)
    }
}

/// Backwards data-flow tracking of register values.
///
/// These queries walk control flow backwards from an address, so they get more
/// expensive with depth and are cached. The caches are invalidated by
/// ``controlFlowReferenceChanged(from:to:mutation:)`` and
/// ``dataReferenceChanged(to:mutation:)``, or cleared outright — a caller that
/// rewrites references without telling the tracker will read stale answers.
public enum RegisterTracking {

    /// Tracks `registerName` backwards from `address`.
    public static func track(
        _ registerName: String,
        at address: Address,
        maximumDepth: Int32
    ) throws(IDAError) -> TrackedRegisterValue {
        var raw = IdaxTrackedRegisterValue()
        try checkStatus(
            idax_registers_track(address, registerName, maximumDepth, &raw),
            "registers.track"
        )
        defer { idax_registers_tracked_value_free(&raw) }
        return TrackedRegisterValue(raw: raw)
    }

    /// The constant value of `registerName` at `address`, when there is one.
    public static func constant(
        of registerName: String,
        at address: Address,
        maximumDepth: Int32
    ) throws(IDAError) -> UInt64? {
        var out: UInt64 = 0
        var hasValue: Int32 = 0
        try checkStatus(
            idax_registers_constant_at(address, registerName, maximumDepth, &out, &hasValue),
            "registers.constant"
        )
        return hasValue != 0 ? out : nil
    }

    /// The stack-pointer delta of `registerName` at `address`, when there is one.
    public static func stackPointerDelta(
        of registerName: String,
        at address: Address
    ) throws(IDAError) -> Int64? {
        var out: Int64 = 0
        var hasValue: Int32 = 0
        try checkStatus(
            idax_registers_stack_delta_at(address, registerName, &out, &hasValue),
            "registers.stackPointerDelta"
        )
        return hasValue != 0 ? out : nil
    }

    /// Whichever of two registers yields a usable value at `address`.
    ///
    /// - Returns: `nil` when neither does.
    public static func nearest(
        _ firstRegister: String,
        or secondRegister: String,
        at address: Address
    ) throws(IDAError) -> NearestRegisterValue? {
        var raw = IdaxNearestRegisterValue()
        var hasValue: Int32 = 0
        try checkStatus(
            idax_registers_nearest_at(address, firstRegister, secondRegister, &raw, &hasValue),
            "registers.nearest"
        )
        guard hasValue != 0 else { return nil }
        defer { idax_registers_nearest_value_free(&raw) }
        return NearestRegisterValue(raw: raw)
    }

    // MARK: - Cache maintenance

    /// Discards the cached control-flow graph.
    public static func clearControlFlowCache() throws(IDAError) {
        try checkStatus(
            idax_registers_clear_control_flow_cache(),
            "registers.clearControlFlowCache"
        )
    }

    /// Discards the cached data-reference index.
    public static func clearDataReferenceCache() throws(IDAError) {
        try checkStatus(
            idax_registers_clear_data_reference_cache(),
            "registers.clearDataReferenceCache"
        )
    }

    /// Tells the tracker a control-flow reference changed, so it can invalidate
    /// only the affected part of its cache.
    public static func controlFlowReferenceChanged(
        from source: Address,
        to destination: Address,
        mutation: ReferenceMutation
    ) throws(IDAError) {
        try checkStatus(
            idax_registers_control_flow_reference_changed(
                source, destination, mutation.rawValue
            ),
            "registers.controlFlowReferenceChanged"
        )
    }

    /// Tells the tracker a data reference changed.
    public static func dataReferenceChanged(
        to destination: Address,
        mutation: ReferenceMutation
    ) throws(IDAError) {
        try checkStatus(
            idax_registers_data_reference_changed(destination, mutation.rawValue),
            "registers.dataReferenceChanged"
        )
    }
}
