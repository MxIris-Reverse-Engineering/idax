internal import CIDAX
import Darwin

/// A half-open address range belonging to an exception construct.
public struct ExceptionRange: Sendable, Equatable {
    public let start: Address
    public let end: Address

    public init(start: Address, end: Address) {
        self.start = start
        self.end = end
    }

    init(raw: IdaxExceptionRange) {
        self.start = raw.start
        self.end = raw.end
    }
}

/// Metadata shared by C++ catch bodies and SEH handler bodies.
public struct ExceptionHandlerMetadata: Sendable {
    /// One or more fragmented handler regions.
    public var regions: [ExceptionRange]
    /// Frame-pointer-relative displacement to the guarded stack region.
    public var stackDisplacement: Int64?
    /// Frame register identifier, absent when none is known.
    public var frameRegister: Int32?

    public init(
        regions: [ExceptionRange] = [],
        stackDisplacement: Int64? = nil,
        frameRegister: Int32? = nil
    ) {
        self.regions = regions
        self.stackDisplacement = stackDisplacement
        self.frameRegister = frameRegister
    }

    init(raw: IdaxExceptionHandlerMetadata) {
        if let regions = raw.regions, raw.regions_count > 0 {
            self.regions = UnsafeBufferPointer(start: regions, count: raw.regions_count)
                .map(ExceptionRange.init(raw:))
        } else {
            self.regions = []
        }
        self.stackDisplacement =
            raw.has_stack_displacement != 0 ? raw.stack_displacement : nil
        self.frameRegister = raw.has_frame_register != 0 ? raw.frame_register : nil
    }
}

/// What a C++ catch clause selects on.
public enum CatchSelectorKind: Int32, Sendable {
    case typed = 0
    case catchAll = 1
    case cleanup = 2
}

/// One C++ catch clause.
public struct ExceptionCatchHandler: Sendable {
    public var metadata: ExceptionHandlerMetadata
    /// Displacement to the caught object, when the clause binds one.
    public var objectDisplacement: Int64?
    public var selectorKind: CatchSelectorKind
    /// Native type identifier; meaningful only for ``CatchSelectorKind/typed``.
    public var typeIdentifier: Int64

    public init(
        metadata: ExceptionHandlerMetadata = ExceptionHandlerMetadata(),
        objectDisplacement: Int64? = nil,
        selectorKind: CatchSelectorKind = .catchAll,
        typeIdentifier: Int64 = 0
    ) {
        self.metadata = metadata
        self.objectDisplacement = objectDisplacement
        self.selectorKind = selectorKind
        self.typeIdentifier = typeIdentifier
    }

    init(raw: IdaxExceptionCatchHandler) {
        self.metadata = ExceptionHandlerMetadata(raw: raw.metadata)
        self.objectDisplacement =
            raw.has_object_displacement != 0 ? raw.object_displacement : nil
        self.selectorKind = CatchSelectorKind(rawValue: raw.selector_kind) ?? .catchAll
        self.typeIdentifier = raw.type_identifier
    }
}

/// What an SEH filter tells the unwinder to do.
public enum SehDisposition: Int32, Sendable {
    case continueExecution = -1
    case continueSearch = 0
    case executeHandler = 1
}

/// One structured-exception handler.
///
/// ``filterRegions`` and ``disposition`` are mutually exclusive, and exactly one
/// must be present: a handler either evaluates a filter expression at runtime or
/// carries a fixed disposition. Supplying both, or neither, is rejected with
/// `Validation` — "SEH disposition is required exactly when filter regions are
/// absent".
public struct ExceptionSehHandler: Sendable {
    public var metadata: ExceptionHandlerMetadata
    /// Regions holding the filter expression. Leave empty when supplying a
    /// fixed ``disposition``.
    public var filterRegions: [ExceptionRange]
    /// Fixed disposition. Leave `nil` when supplying ``filterRegions``.
    public var disposition: SehDisposition?

    public init(
        metadata: ExceptionHandlerMetadata = ExceptionHandlerMetadata(),
        filterRegions: [ExceptionRange] = [],
        disposition: SehDisposition? = nil
    ) {
        self.metadata = metadata
        self.filterRegions = filterRegions
        self.disposition = disposition
    }

    init(raw: IdaxExceptionSehHandler) {
        self.metadata = ExceptionHandlerMetadata(raw: raw.metadata)
        if let filters = raw.filter_regions, raw.filter_regions_count > 0 {
            self.filterRegions = UnsafeBufferPointer(
                start: filters, count: raw.filter_regions_count
            ).map(ExceptionRange.init(raw:))
        } else {
            self.filterRegions = []
        }
        self.disposition = raw.has_disposition != 0
            ? SehDisposition(rawValue: raw.disposition)
            : nil
    }
}

/// The handlers guarding a protected region: either C++ catches or one SEH
/// handler, never both.
///
/// C models this as a tag plus two fields, only one of which is meaningful.
/// Making it an enum means an invalid combination cannot be expressed.
public enum ExceptionHandlerSet: Sendable {
    case cppCatches([ExceptionCatchHandler])
    case structuredHandler(ExceptionSehHandler)
}

/// A protected region together with what handles exceptions raised inside it.
public struct ExceptionBlockDefinition: Sendable {
    public var protectedRegions: [ExceptionRange]
    public var handlers: ExceptionHandlerSet

    public init(protectedRegions: [ExceptionRange], handlers: ExceptionHandlerSet) {
        self.protectedRegions = protectedRegions
        self.handlers = handlers
    }

    init(raw: IdaxExceptionBlockDefinition) {
        if let regions = raw.protected_regions, raw.protected_regions_count > 0 {
            self.protectedRegions = UnsafeBufferPointer(
                start: regions, count: raw.protected_regions_count
            ).map(ExceptionRange.init(raw:))
        } else {
            self.protectedRegions = []
        }
        if raw.handler_kind == 0 {
            var catches: [ExceptionCatchHandler] = []
            if let rawCatches = raw.catches, raw.catches_count > 0 {
                catches = UnsafeBufferPointer(start: rawCatches, count: raw.catches_count)
                    .map(ExceptionCatchHandler.init(raw:))
            }
            self.handlers = .cppCatches(catches)
        } else {
            self.handlers = .structuredHandler(ExceptionSehHandler(raw: raw.seh))
        }
    }
}

/// A block as stored in the database, with its nesting depth.
public struct ExceptionBlock: Sendable {
    public let definition: ExceptionBlockDefinition
    /// How deeply this block nests inside other blocks.
    public let nestingLevel: UInt8

    init(raw: IdaxExceptionBlock) {
        self.definition = ExceptionBlockDefinition(raw: raw.definition)
        self.nestingLevel = raw.nesting_level
    }
}

/// Which parts of an exception construct an address may fall in.
public struct ExceptionLocation: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let cppTry = ExceptionLocation(rawValue: 0x01)
    public static let cppHandler = ExceptionLocation(rawValue: 0x02)
    public static let sehTry = ExceptionLocation(rawValue: 0x04)
    public static let sehHandler = ExceptionLocation(rawValue: 0x08)
    public static let sehFilter = ExceptionLocation(rawValue: 0x10)
    /// Every location above, but not ``unwindFallthrough``.
    public static let any = ExceptionLocation(rawValue: 0x1F)
    public static let unwindFallthrough = ExceptionLocation(rawValue: 0x20)
}

/// C++ exception and structured-exception handler regions.
///
/// This is the metadata describing where `try` bodies, catch clauses and SEH
/// filters live — not Swift error handling, despite the name of the underlying
/// C++ namespace.
public enum ExceptionRegion {

    /// Every block overlapping the given range.
    public static func list(start: Address, end: Address) throws(IDAError) -> [ExceptionBlock] {
        var pointer: UnsafeMutablePointer<IdaxExceptionBlock>? = nil
        var count: Int = 0
        try checkStatus(
            idax_exception_list(start, end, &pointer, &count),
            "exception.list"
        )
        defer { idax_exception_blocks_free(pointer, count) }
        guard let pointer, count > 0 else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).map(ExceptionBlock.init(raw:))
    }

    /// Removes every block in the given range.
    public static func remove(start: Address, end: Address) throws(IDAError) {
        try checkStatus(idax_exception_remove(start, end), "exception.remove")
    }

    /// Records a block.
    public static func add(_ definition: ExceptionBlockDefinition) throws(IDAError) {
        var builder = ExceptionDefinitionBuilder(definition)
        defer { builder.release() }
        try checkStatus(
            withUnsafePointer(to: &builder.raw) { idax_exception_add($0) },
            "exception.add"
        )
    }

    /// The start of the system-defined region covering `address`, when there is one.
    public static func systemRegionStart(at address: Address) throws(IDAError) -> Address? {
        var out: UInt64 = 0
        var hasValue: Int32 = 0
        try checkStatus(
            idax_exception_system_region_start(address, &out, &hasValue),
            "exception.systemRegionStart"
        )
        return hasValue != 0 ? out : nil
    }

    /// Whether `address` falls inside any of `locations`.
    public static func contains(
        _ address: Address,
        locations: ExceptionLocation = .any
    ) throws(IDAError) -> Bool {
        try withOutput("exception.contains", Int32(0)) {
            idax_exception_contains(address, locations.rawValue, $0)
        } != 0
    }
}

// MARK: - Building the C definition

/// Assembles the nested C structure `idax_exception_add` expects.
///
/// The definition is a tree of arrays — protected regions, catch clauses, and
/// each clause's own regions — so borrowing them all through nested
/// `withUnsafeBufferPointer` closures would nest as deeply as the data. This
/// allocates each array instead and frees them together in ``release()``. The
/// shim only reads through the pointers, so a plain allocation is enough.
private struct ExceptionDefinitionBuilder {
    var raw = IdaxExceptionBlockDefinition()
    private var allocations: [UnsafeMutableRawPointer] = []

    init(_ definition: ExceptionBlockDefinition) {
        (raw.protected_regions, raw.protected_regions_count) =
            allocateRanges(definition.protectedRegions)

        switch definition.handlers {
        case .cppCatches(let catches):
            raw.handler_kind = 0
            if catches.isEmpty {
                raw.catches = nil
                raw.catches_count = 0
            } else {
                let buffer = UnsafeMutablePointer<IdaxExceptionCatchHandler>
                    .allocate(capacity: catches.count)
                for (index, entry) in catches.enumerated() {
                    var rawCatch = IdaxExceptionCatchHandler()
                    rawCatch.metadata = makeMetadata(entry.metadata)
                    rawCatch.has_object_displacement = entry.objectDisplacement == nil ? 0 : 1
                    rawCatch.object_displacement = entry.objectDisplacement ?? 0
                    rawCatch.selector_kind = entry.selectorKind.rawValue
                    rawCatch.type_identifier = entry.typeIdentifier
                    buffer[index] = rawCatch
                }
                allocations.append(UnsafeMutableRawPointer(buffer))
                raw.catches = buffer
                raw.catches_count = catches.count
            }

        case .structuredHandler(let handler):
            raw.handler_kind = 1
            var rawSeh = IdaxExceptionSehHandler()
            rawSeh.metadata = makeMetadata(handler.metadata)
            (rawSeh.filter_regions, rawSeh.filter_regions_count) =
                allocateRanges(handler.filterRegions)
            rawSeh.has_disposition = handler.disposition == nil ? 0 : 1
            rawSeh.disposition = handler.disposition?.rawValue ?? 0
            raw.seh = rawSeh
        }
    }

    private mutating func allocateRanges(
        _ ranges: [ExceptionRange]
    ) -> (UnsafeMutablePointer<IdaxExceptionRange>?, Int) {
        guard !ranges.isEmpty else { return (nil, 0) }
        let buffer = UnsafeMutablePointer<IdaxExceptionRange>.allocate(capacity: ranges.count)
        for (index, range) in ranges.enumerated() {
            var rawRange = IdaxExceptionRange()
            rawRange.start = range.start
            rawRange.end = range.end
            buffer[index] = rawRange
        }
        allocations.append(UnsafeMutableRawPointer(buffer))
        return (buffer, ranges.count)
    }

    private mutating func makeMetadata(
        _ metadata: ExceptionHandlerMetadata
    ) -> IdaxExceptionHandlerMetadata {
        var rawMetadata = IdaxExceptionHandlerMetadata()
        (rawMetadata.regions, rawMetadata.regions_count) = allocateRanges(metadata.regions)
        rawMetadata.has_stack_displacement = metadata.stackDisplacement == nil ? 0 : 1
        rawMetadata.stack_displacement = metadata.stackDisplacement ?? 0
        rawMetadata.has_frame_register = metadata.frameRegister == nil ? 0 : 1
        rawMetadata.frame_register = metadata.frameRegister ?? 0
        return rawMetadata
    }

    mutating func release() {
        for allocation in allocations {
            allocation.deallocate()
        }
        allocations.removeAll()
    }
}
