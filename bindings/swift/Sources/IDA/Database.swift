import CIDA

/// Database lifecycle and metadata operations.
///
/// Mirrors C++ `ida::database`.
public enum Database {

    // MARK: - Lifecycle

    public static func initialize() throws(IDAError) {
        try checkStatus(idax_database_init(0, nil), "database.init")
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
}
