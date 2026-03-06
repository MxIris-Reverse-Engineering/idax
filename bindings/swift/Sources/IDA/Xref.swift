import CIDA
import Darwin

/// Cross-reference descriptor.
public struct CrossReference: Sendable {
    public let from: Address
    public let to: Address
    public let isCode: Bool
    public let type: Int32
    public let isUserDefined: Bool
}

/// Cross-reference enumeration and mutation.
///
/// Mirrors C++ `ida::xref`.
public enum Xref {
    public static func refsFrom(_ address: Address) throws(IDAError) -> [CrossReference] {
        try xrefArray("xref.refsFrom") { idax_xref_refs_from(address, $0, $1) }
    }

    public static func refsTo(_ address: Address) throws(IDAError) -> [CrossReference] {
        try xrefArray("xref.refsTo") { idax_xref_refs_to(address, $0, $1) }
    }

    public static func codeRefsFrom(_ address: Address) throws(IDAError) -> [Address] {
        try withAddressArrayOutput("xref.codeRefsFrom") { idax_xref_code_refs_from(address, $0, $1) }
    }

    public static func codeRefsTo(_ address: Address) throws(IDAError) -> [Address] {
        try withAddressArrayOutput("xref.codeRefsTo") { idax_xref_code_refs_to(address, $0, $1) }
    }

    public static func dataRefsFrom(_ address: Address) throws(IDAError) -> [Address] {
        try withAddressArrayOutput("xref.dataRefsFrom") { idax_xref_data_refs_from(address, $0, $1) }
    }

    public static func dataRefsTo(_ address: Address) throws(IDAError) -> [Address] {
        try withAddressArrayOutput("xref.dataRefsTo") { idax_xref_data_refs_to(address, $0, $1) }
    }

    public static func addCode(from: Address, to: Address, type: Int32 = 0) throws(IDAError) {
        try checkStatus(idax_xref_add_code(from, to, type), "xref.addCode")
    }

    public static func addData(from: Address, to: Address, type: Int32 = 0) throws(IDAError) {
        try checkStatus(idax_xref_add_data(from, to, type), "xref.addData")
    }

    public static func removeCode(from: Address, to: Address) throws(IDAError) {
        try checkStatus(idax_xref_remove_code(from, to), "xref.removeCode")
    }

    public static func removeData(from: Address, to: Address) throws(IDAError) {
        try checkStatus(idax_xref_remove_data(from, to), "xref.removeData")
    }
}

private func xrefArray(
    _ fallback: String,
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<IdaxXref>?>, UnsafeMutablePointer<Int>) -> Int32
) throws(IDAError) -> [CrossReference] {
    var ptr: UnsafeMutablePointer<IdaxXref>? = nil
    var count: Int = 0
    try checkStatus(body(&ptr, &count), fallback)
    defer { free(ptr) }
    guard let ptr, count > 0 else { return [] }
    let buf = UnsafeBufferPointer(start: ptr, count: count)
    return buf.map { r in
        CrossReference(
            from: r.from, to: r.to,
            isCode: r.is_code != 0,
            type: r.type,
            isUserDefined: r.user_defined != 0
        )
    }
}
