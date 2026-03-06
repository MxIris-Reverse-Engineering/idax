import CIDA
import Darwin

/// Fixup/relocation descriptor.
public struct Fixup: Sendable {
    public let source: Address
    public let type: Int32
    public let flags: UInt32
    public let base: Address
    public let target: Address
    public let selector: UInt16
    public let offset: UInt64
    public let displacement: Int64

    public static func at(_ source: Address) throws(IDAError) -> Fixup {
        var raw = IdaxFixup()
        try checkStatus(idax_fixup_at(source, &raw), "fixup.at")
        return Fixup(raw: raw)
    }

    public static func exists(at source: Address) -> Bool {
        idax_fixup_exists(source) != 0
    }

    public static func inRange(start: Address, end: Address) throws(IDAError) -> [Fixup] {
        var ptr: UnsafeMutablePointer<IdaxFixup>? = nil
        var count: Int = 0
        try checkStatus(idax_fixup_in_range(start, end, &ptr, &count), "fixup.inRange")
        defer { free(ptr) }
        guard let ptr, count > 0 else { return [] }
        let buf = UnsafeBufferPointer(start: ptr, count: count)
        return buf.map { Fixup(raw: $0) }
    }

    public static func remove(at source: Address) throws(IDAError) {
        try checkStatus(idax_fixup_remove(source), "fixup.remove")
    }

    init(raw: IdaxFixup) {
        self.source = raw.source
        self.type = raw.type
        self.flags = raw.flags
        self.base = raw.base
        self.target = raw.target
        self.selector = raw.selector
        self.offset = raw.offset
        self.displacement = raw.displacement
    }
}
