internal import CIDAX

/// Compiler metadata returned by `Database.compilerInfo()`.
public struct CompilerInfo: Sendable {
    public let id: UInt32
    public let uncertain: Bool
    public let name: String
    public let abbreviation: String
}

/// A single imported symbol within an import module.
public struct ImportSymbol: Sendable {
    public let address: Address
    public let name: String
    public let ordinal: UInt64
}

/// An import module containing its symbols.
public struct ImportModule: Sendable {
    public let index: Int
    public let name: String
    public let symbols: [ImportSymbol]
}

/// A database snapshot (recursive tree node).
public struct Snapshot: Sendable {
    public let id: Int64
    public let flags: UInt16
    public let description: String
    public let filename: String
    public let children: [Snapshot]
}

/// Database lifecycle and metadata operations.
///
/// Mirrors C++ `ida::database`.
public enum Database {

    // MARK: - Lifecycle

    public static func initialize() throws(IDAError) {
        try checkStatus(idax_database_init(0, nil), "database.init")
        idax_sync_ida_globals()
    }

    public static func open(_ path: String, autoAnalysis: Bool = true) throws(IDAError) {
        try checkStatus(
            path.withCString { idax_database_open($0, autoAnalysis ? 1 : 0) },
            "database.open"
        )
    }

    public static func save() throws(IDAError) {
        try checkStatus(idax_database_save(), "database.save")
    }

    public static func close(save: Bool = false) throws(IDAError) {
        try checkStatus(idax_database_close(save ? 1 : 0), "database.close")
    }

    // MARK: - Metadata

    public static func inputFilePath() throws(IDAError) -> String {
        try withStringOutput("database.inputFilePath") { idax_database_input_file_path($0) }
    }

    public static func fileTypeName() throws(IDAError) -> String {
        try withStringOutput("database.fileTypeName") { idax_database_file_type_name($0) }
    }

    public static func loaderFormatName() throws(IDAError) -> String {
        try withStringOutput("database.loaderFormatName") { idax_database_loader_format_name($0) }
    }

    public static func inputMD5() throws(IDAError) -> String {
        try withStringOutput("database.inputMD5") { idax_database_input_md5($0) }
    }

    public static func processorName() throws(IDAError) -> String {
        try withStringOutput("database.processorName") { idax_database_processor_name($0) }
    }

    public static func abiName() throws(IDAError) -> String {
        try withStringOutput("database.abiName") { idax_database_abi_name($0) }
    }

    public static func imageBase() throws(IDAError) -> Address {
        try withOutput("database.imageBase", UInt64(0)) { idax_database_image_base($0) }
    }

    public static func minAddress() throws(IDAError) -> Address {
        try withOutput("database.minAddress", UInt64(0)) { idax_database_min_address($0) }
    }

    public static func maxAddress() throws(IDAError) -> Address {
        try withOutput("database.maxAddress", UInt64(0)) { idax_database_max_address($0) }
    }

    public static func addressBitness() throws(IDAError) -> Int {
        Int(try withOutput("database.addressBitness", Int32(0)) { idax_database_address_bitness($0) })
    }

    public static func setAddressBitness(_ bits: Int) throws(IDAError) {
        try checkStatus(idax_database_set_address_bitness(Int32(bits)), "database.setAddressBitness")
    }

    public static func isBigEndian() throws(IDAError) -> Bool {
        try withOutput("database.isBigEndian", Int32(0)) { idax_database_is_big_endian($0) } != 0
    }

    public static func addressSpan() throws(IDAError) -> AddressSize {
        try withOutput("database.addressSpan", UInt64(0)) { idax_database_address_span($0) }
    }

    public static func processorID() throws(IDAError) -> Int32 {
        try withOutput("database.processorID", Int32(0)) { idax_database_processor_id($0) }
    }

    // MARK: - Binary Loading

    public static func openBinary(_ path: String, mode: Int) throws(IDAError) {
        try checkStatus(
            path.withCString { idax_database_open_binary($0, Int32(mode)) },
            "database.openBinary"
        )
    }

    public static func openNonBinary(_ path: String, mode: Int) throws(IDAError) {
        try checkStatus(
            path.withCString { idax_database_open_non_binary($0, Int32(mode)) },
            "database.openNonBinary"
        )
    }

    public static func fileToDatabase(
        filePath: String, fileOffset: Int64, address: Address,
        size: UInt64, patchable: Bool, remote: Bool
    ) throws(IDAError) {
        try checkStatus(
            filePath.withCString {
                idax_database_file_to_database(
                    $0, fileOffset, address, size,
                    patchable ? 1 : 0, remote ? 1 : 0
                )
            },
            "database.fileToDatabase"
        )
    }

    public static func memoryToDatabase(
        bytes: Span<UInt8>, address: Address, fileOffset: Int64
    ) throws(IDAError) {
        try checkStatus(
            idax_database_memory_to_database(bytes, address, fileOffset),
            "database.memoryToDatabase"
        )
    }

    // MARK: - Compiler Info

    public static func compilerInfo() throws(IDAError) -> CompilerInfo {
        var raw = IdaxDatabaseCompilerInfo()
        try checkStatus(idax_database_compiler_info(&raw), "database.compilerInfo")
        defer { idax_database_compiler_info_free(&raw) }
        return CompilerInfo(
            id: raw.id,
            uncertain: raw.uncertain != 0,
            name: borrowCString(raw.name),
            abbreviation: borrowCString(raw.abbreviation)
        )
    }

    // MARK: - Imports

    public static func importModules() throws(IDAError) -> [ImportModule] {
        var ptr: UnsafeMutablePointer<IdaxDatabaseImportModule>? = nil
        var count: Int = 0
        try checkStatus(idax_database_import_modules(&ptr, &count), "database.importModules")
        defer { idax_database_import_modules_free(ptr, count) }
        guard let ptr, count > 0 else { return [] }
        var result: [ImportModule] = []
        for i in 0..<count {
            let raw = ptr[i]
            var symbols: [ImportSymbol] = []
            if let symPtr = raw.symbols, raw.symbol_count > 0 {
                for j in 0..<raw.symbol_count {
                    let s = symPtr[j]
                    symbols.append(ImportSymbol(
                        address: s.address,
                        name: borrowCString(s.name),
                        ordinal: s.ordinal
                    ))
                }
            }
            result.append(ImportModule(
                index: raw.index,
                name: borrowCString(raw.name),
                symbols: symbols
            ))
        }
        return result
    }

    // MARK: - Snapshots

    public static func snapshots() throws(IDAError) -> [Snapshot] {
        var ptr: UnsafeMutablePointer<IdaxDatabaseSnapshot>? = nil
        var count: Int = 0
        try checkStatus(idax_database_snapshots(&ptr, &count), "database.snapshots")
        defer { idax_database_snapshots_free(ptr, count) }
        guard let ptr, count > 0 else { return [] }
        var result: [Snapshot] = []
        for i in 0..<count {
            result.append(convertSnapshot(ptr[i]))
        }
        return result
    }

    public static func setSnapshotDescription(_ description: String) throws(IDAError) {
        try checkStatus(
            description.withCString { idax_database_set_snapshot_description($0) },
            "database.setSnapshotDescription"
        )
    }

    public static func isSnapshotDatabase() throws(IDAError) -> Bool {
        try withOutput("database.isSnapshotDatabase", Int32(0)) {
            idax_database_is_snapshot_database($0)
        } != 0
    }

    // MARK: - Private Helpers

    private static func convertSnapshot(_ raw: IdaxDatabaseSnapshot) -> Snapshot {
        var kids: [Snapshot] = []
        if let childPtr = raw.children, raw.child_count > 0 {
            for i in 0..<raw.child_count {
                kids.append(convertSnapshot(childPtr[i]))
            }
        }
        return Snapshot(
            id: raw.id,
            flags: raw.flags,
            description: borrowCString(raw.description),
            filename: borrowCString(raw.filename),
            children: kids
        )
    }
}
