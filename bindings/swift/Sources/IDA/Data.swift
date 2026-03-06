import CIDA

/// Byte-level read, write, patch, and define operations.
///
/// Mirrors C++ `ida::data`.
public enum Data {

    // MARK: - Read

    public static func readByte(at address: Address) throws(IDAError) -> UInt8 {
        try withOutput("data.readByte", UInt8(0)) { idax_data_read_byte(address, $0) }
    }

    public static func readWord(at address: Address) throws(IDAError) -> UInt16 {
        try withOutput("data.readWord", UInt16(0)) { idax_data_read_word(address, $0) }
    }

    public static func readDword(at address: Address) throws(IDAError) -> UInt32 {
        try withOutput("data.readDword", UInt32(0)) { idax_data_read_dword(address, $0) }
    }

    public static func readQword(at address: Address) throws(IDAError) -> UInt64 {
        try withOutput("data.readQword", UInt64(0)) { idax_data_read_qword(address, $0) }
    }

    public static func readBytes(at address: Address, count: UInt64) throws(IDAError) -> [UInt8] {
        var ptr: UnsafeMutablePointer<UInt8>? = nil
        var len: Int = 0
        try checkStatus(idax_data_read_bytes(address, count, &ptr, &len), "data.readBytes")
        defer { idax_free_bytes(ptr) }
        guard let ptr, len > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: len))
    }

    public static func readString(at address: Address, maxLength: UInt64 = 4096) throws(IDAError) -> String {
        try withStringOutput("data.readString") { idax_data_read_string(address, maxLength, $0) }
    }

    // MARK: - Write

    public static func writeByte(_ value: UInt8, at address: Address) throws(IDAError) {
        try checkStatus(idax_data_write_byte(address, value), "data.writeByte")
    }

    public static func writeWord(_ value: UInt16, at address: Address) throws(IDAError) {
        try checkStatus(idax_data_write_word(address, value), "data.writeWord")
    }

    public static func writeDword(_ value: UInt32, at address: Address) throws(IDAError) {
        try checkStatus(idax_data_write_dword(address, value), "data.writeDword")
    }

    public static func writeQword(_ value: UInt64, at address: Address) throws(IDAError) {
        try checkStatus(idax_data_write_qword(address, value), "data.writeQword")
    }

    public static func writeBytes(_ data: [UInt8], at address: Address) throws(IDAError) {
        try checkStatus(
            data.withUnsafeBufferPointer { idax_data_write_bytes(address, $0.baseAddress, $0.count) },
            "data.writeBytes"
        )
    }

    // MARK: - Patch

    public static func patchByte(_ value: UInt8, at address: Address) throws(IDAError) {
        try checkStatus(idax_data_patch_byte(address, value), "data.patchByte")
    }

    public static func patchWord(_ value: UInt16, at address: Address) throws(IDAError) {
        try checkStatus(idax_data_patch_word(address, value), "data.patchWord")
    }

    public static func patchDword(_ value: UInt32, at address: Address) throws(IDAError) {
        try checkStatus(idax_data_patch_dword(address, value), "data.patchDword")
    }

    public static func patchQword(_ value: UInt64, at address: Address) throws(IDAError) {
        try checkStatus(idax_data_patch_qword(address, value), "data.patchQword")
    }

    public static func patchBytes(_ data: [UInt8], at address: Address) throws(IDAError) {
        try checkStatus(
            data.withUnsafeBufferPointer { idax_data_patch_bytes(address, $0.baseAddress, $0.count) },
            "data.patchBytes"
        )
    }

    public static func revertPatch(at address: Address) throws(IDAError) {
        try checkStatus(idax_data_revert_patch(address), "data.revertPatch")
    }

    // MARK: - Original values

    public static func originalByte(at address: Address) throws(IDAError) -> UInt8 {
        try withOutput("data.originalByte", UInt8(0)) { idax_data_original_byte(address, $0) }
    }

    // MARK: - Define

    public static func defineByte(at address: Address, count: UInt64 = 1) throws(IDAError) {
        try checkStatus(idax_data_define_byte(address, count), "data.defineByte")
    }

    public static func defineWord(at address: Address, count: UInt64 = 1) throws(IDAError) {
        try checkStatus(idax_data_define_word(address, count), "data.defineWord")
    }

    public static func defineDword(at address: Address, count: UInt64 = 1) throws(IDAError) {
        try checkStatus(idax_data_define_dword(address, count), "data.defineDword")
    }

    public static func defineQword(at address: Address, count: UInt64 = 1) throws(IDAError) {
        try checkStatus(idax_data_define_qword(address, count), "data.defineQword")
    }

    public static func undefine(at address: Address, count: UInt64) throws(IDAError) {
        try checkStatus(idax_data_undefine(address, count), "data.undefine")
    }

    // MARK: - Search

    public static func findBinaryPattern(
        _ pattern: String, start: Address, end: Address, forward: Bool = true
    ) throws(IDAError) -> Address {
        try withOutput("data.findBinaryPattern", UInt64(0)) { out in
            pattern.withCString { idax_data_find_binary_pattern(start, end, $0, forward ? 1 : 0, out) }
        }
    }
}
