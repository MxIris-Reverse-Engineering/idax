import CIDA

/// Segment type classification.
public enum SegmentType: Int32, Sendable {
    case normal = 0, external, code, data, bss
    case absoluteSymbols, common, null, undefined
    case `import`, internalMemory, group
}

/// Read/write/execute permission flags.
public struct Permissions: Sendable, Equatable {
    public let read: Bool
    public let write: Bool
    public let execute: Bool
}

/// Opaque snapshot of a segment.
public struct Segment: Sendable {
    public let start: Address
    public let end: Address
    public let name: String
    public let className: String
    public let bitness: Int
    public let segmentType: SegmentType
    public let permissions: Permissions
    public let isVisible: Bool

    public var size: AddressSize { end &- start }

    // MARK: - Queries

    public static func at(_ address: Address) throws(IDAError) -> Segment {
        var raw = IdaxSegment()
        try checkStatus(idax_segment_at(address, &raw), "segment.at")
        defer { idax_segment_free(&raw) }
        return Segment(raw: raw)
    }

    public static func byName(_ name: String) throws(IDAError) -> Segment {
        var raw = IdaxSegment()
        try checkStatus(
            name.withCString { idax_segment_by_name($0, &raw) },
            "segment.byName"
        )
        defer { idax_segment_free(&raw) }
        return Segment(raw: raw)
    }

    public static func byIndex(_ index: Int) throws(IDAError) -> Segment {
        var raw = IdaxSegment()
        try checkStatus(idax_segment_by_index(index, &raw), "segment.byIndex")
        defer { idax_segment_free(&raw) }
        return Segment(raw: raw)
    }

    public static func count() throws(IDAError) -> Int {
        var out: Int = 0
        try checkStatus(idax_segment_count(&out), "segment.count")
        return out
    }

    public static func all() throws(IDAError) -> [Segment] {
        let n = try count()
        var result: [Segment] = []
        result.reserveCapacity(n)
        for i in 0..<n { result.append(try byIndex(i)) }
        return result
    }

    // MARK: - Mutation

    public static func create(
        start: Address, end: Address,
        name: String, className: String = "",
        type: SegmentType = .normal
    ) throws(IDAError) {
        try checkStatus(
            name.withCString { n in
                className.withCString { c in
                    idax_segment_create(start, end, n, c, type.rawValue)
                }
            },
            "segment.create"
        )
    }

    public static func remove(at address: Address) throws(IDAError) {
        try checkStatus(idax_segment_remove(address), "segment.remove")
    }

    public static func setName(_ name: String, at address: Address) throws(IDAError) {
        try checkStatus(
            name.withCString { idax_segment_set_name(address, $0) },
            "segment.setName"
        )
    }

    public static func setPermissions(
        at address: Address, read: Bool, write: Bool, execute: Bool
    ) throws(IDAError) {
        try checkStatus(
            idax_segment_set_permissions(
                address,
                read ? 1 : 0, write ? 1 : 0, execute ? 1 : 0
            ),
            "segment.setPermissions"
        )
    }

    // MARK: - Internal

    init(raw: IdaxSegment) {
        self.start = raw.start
        self.end = raw.end
        self.bitness = Int(raw.bitness)
        self.segmentType = SegmentType(rawValue: Int32(raw.type)) ?? .undefined
        self.permissions = Permissions(
            read: raw.perm_read != 0,
            write: raw.perm_write != 0,
            execute: raw.perm_exec != 0
        )
        self.name = takeCString(raw.name)
        self.className = takeCString(raw.class_name)
        self.isVisible = raw.visible != 0
    }
}
