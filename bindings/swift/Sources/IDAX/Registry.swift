internal import CIDAX
import Darwin

/// Storage kind of a registry value.
///
/// Booleans are stored as integers; there is no separate kind for them.
public enum RegistryValueKind: Int32, Sendable {
    case string = 1
    case binary = 3
    case integer = 4
}

/// One deterministic ordered string-list update.
public struct RegistryStringListUpdate: Sendable {
    /// Value to front-insert after removing its existing matching positions.
    public var add: String?
    /// Value whose matching positions are removed.
    public var remove: String?
    /// Maximum retained records, in the closed range 1...1000.
    public var maximumRecords: Int
    /// Apply the SDK's UTF-8 case-insensitive comparison to add/remove matches.
    public var ignoreCase: Bool

    public init(
        add: String? = nil,
        remove: String? = nil,
        maximumRecords: Int = 1000,
        ignoreCase: Bool = false
    ) {
        self.add = add
        self.remove = remove
        self.maximumRecords = maximumRecords
        self.ignoreCase = ignoreCase
    }
}

/// Scoped access to one persistent IDA configuration key.
///
/// A store owns only the key text — it holds no native registry object and does
/// not mutate IDA's process-global registry root, so it is an ordinary value.
/// The key need not exist when the store is opened; ``exists()`` reports whether
/// it does.
///
/// Reads return `nil` for an absent value and throw `Conflict` when the value
/// exists with a different storage kind, so a missing setting and a
/// wrongly-typed one are distinguishable.
public struct RegistryStore: Sendable {
    /// The key this store is scoped to.
    public let key: String

    private init(validatedKey: String) {
        self.key = validatedKey
    }

    /// Opens a scoped key, which need not already exist.
    public static func open(_ key: String) throws(IDAError) -> RegistryStore {
        try checkStatus(idax_registry_open(key), "registry.open")
        return RegistryStore(validatedKey: key)
    }

    /// Derives a store for one child path component.
    public func child(_ name: String) throws(IDAError) -> RegistryStore {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(idax_registry_child(key, name, &out), "registry.child")
        return RegistryStore(validatedKey: takeCString(out))
    }

    /// Whether this key currently exists.
    public func exists() throws(IDAError) -> Bool {
        try withOutput("registry.exists", Int32(0)) {
            idax_registry_exists(key, $0)
        } != 0
    }

    /// Names of the direct child keys.
    public func childKeys() throws(IDAError) -> [String] {
        try readStrings("registry.childKeys") { idax_registry_child_keys(key, $0, $1) }
    }

    /// Names of the values stored directly under this key.
    public func valueNames() throws(IDAError) -> [String] {
        try readStrings("registry.valueNames") { idax_registry_value_names(key, $0, $1) }
    }

    /// Whether a value called `name` exists under this key.
    public func contains(_ name: String) throws(IDAError) -> Bool {
        try withOutput("registry.contains", Int32(0)) {
            idax_registry_contains(key, name, $0)
        } != 0
    }

    /// Storage kind of `name`, or `nil` when the value is absent.
    public func valueKind(of name: String) throws(IDAError) -> RegistryValueKind? {
        var hasValue: Int32 = 0
        var raw: Int32 = 0
        try checkStatus(
            idax_registry_value_kind(key, name, &hasValue, &raw),
            "registry.valueKind"
        )
        guard hasValue != 0 else { return nil }
        return RegistryValueKind(rawValue: raw)
    }

    // MARK: - Typed reads and writes

    /// Reads a string value, or `nil` when absent.
    public func readString(_ name: String) throws(IDAError) -> String? {
        var hasValue: Int32 = 0
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(
            idax_registry_read_string(key, name, &hasValue, &out),
            "registry.readString"
        )
        guard hasValue != 0 else {
            if out != nil { _ = takeCString(out) }
            return nil
        }
        return takeCString(out)
    }

    /// Writes a string value, verifying the typed readback.
    public func writeString(_ value: String, to name: String) throws(IDAError) {
        try checkStatus(
            idax_registry_write_string(key, name, value),
            "registry.writeString"
        )
    }

    /// Reads binary octets, or `nil` when absent.
    public func readBinary(_ name: String) throws(IDAError) -> [UInt8]? {
        var hasValue: Int32 = 0
        var pointer: UnsafeMutablePointer<UInt8>? = nil
        var count: Int = 0
        try checkStatus(
            idax_registry_read_binary(key, name, &hasValue, &pointer, &count),
            "registry.readBinary"
        )
        defer { idax_free_bytes(pointer) }
        guard hasValue != 0 else { return nil }
        guard let pointer, count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    /// Writes binary octets. An empty value is permitted and round-trips.
    public func writeBinary(_ value: [UInt8], to name: String) throws(IDAError) {
        let status = value.withUnsafeBufferPointer { buffer in
            idax_registry_write_binary(key, name, buffer.baseAddress, buffer.count)
        }
        try checkStatus(status, "registry.writeBinary")
    }

    /// Reads a signed 32-bit integer, or `nil` when absent.
    public func readInteger(_ name: String) throws(IDAError) -> Int32? {
        var hasValue: Int32 = 0
        var out: Int32 = 0
        try checkStatus(
            idax_registry_read_integer(key, name, &hasValue, &out),
            "registry.readInteger"
        )
        return hasValue != 0 ? out : nil
    }

    /// Writes a signed 32-bit integer, verifying the exact readback.
    public func writeInteger(_ value: Int32, to name: String) throws(IDAError) {
        try checkStatus(
            idax_registry_write_integer(key, name, value),
            "registry.writeInteger"
        )
    }

    /// Reads integer storage as a boolean; any nonzero value is `true`.
    public func readBoolean(_ name: String) throws(IDAError) -> Bool? {
        var hasValue: Int32 = 0
        var out: Int32 = 0
        try checkStatus(
            idax_registry_read_boolean(key, name, &hasValue, &out),
            "registry.readBoolean"
        )
        return hasValue != 0 ? out != 0 : nil
    }

    /// Writes a boolean into integer storage.
    public func writeBoolean(_ value: Bool, to name: String) throws(IDAError) {
        try checkStatus(
            idax_registry_write_boolean(key, name, value ? 1 : 0),
            "registry.writeBoolean"
        )
    }

    // MARK: - Removal

    /// Erases one value.
    ///
    /// - Returns: whether a value was actually removed.
    @discardableResult
    public func eraseValue(_ name: String) throws(IDAError) -> Bool {
        try withOutput("registry.eraseValue", Int32(0)) {
            idax_registry_erase_value(key, name, $0)
        } != 0
    }

    /// Erases this key, which must have no children.
    ///
    /// - Returns: whether the key existed.
    @discardableResult
    public func eraseKey() throws(IDAError) -> Bool {
        try withOutput("registry.eraseKey", Int32(0)) {
            idax_registry_erase_key(key, $0)
        } != 0
    }

    /// Erases this key and everything beneath it.
    ///
    /// - Returns: whether the key existed.
    @discardableResult
    public func eraseTree() throws(IDAError) -> Bool {
        try withOutput("registry.eraseTree", Int32(0)) {
            idax_registry_erase_tree(key, $0)
        } != 0
    }

    // MARK: - String lists

    /// Reads this key's ordered string list.
    public func readStringList() throws(IDAError) -> [String] {
        try readStrings("registry.readStringList") {
            idax_registry_read_string_list(key, $0, $1)
        }
    }

    /// Replaces this key's ordered string list.
    public func writeStringList(_ values: [String]) throws(IDAError) {
        let cStrings = values.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        let status = cStrings.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
                idax_registry_write_string_list(key, rebound.baseAddress, rebound.count)
            }
        }
        try checkStatus(status, "registry.writeStringList")
    }

    /// Applies one ordered add/remove update to this key's string list.
    ///
    /// The add is front-inserted after its existing matching positions are
    /// removed, so applying the same value twice does not duplicate it.
    public func updateStringList(_ update: RegistryStringListUpdate) throws(IDAError) {
        try checkStatus(
            idax_registry_update_string_list(
                key,
                update.add,
                update.remove,
                update.maximumRecords,
                update.ignoreCase ? 1 : 0
            ),
            "registry.updateStringList"
        )
    }

    // MARK: - Shared string-array plumbing

    private func readStrings(
        _ fallback: String,
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>,
            UnsafeMutablePointer<Int>
        ) -> Int32
    ) throws(IDAError) -> [String] {
        var pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        var count: Int = 0
        try checkStatus(body(&pointer, &count), fallback)
        defer { idax_registry_strings_free(pointer, count) }
        guard let pointer, count > 0 else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).map { borrowCString($0) }
    }
}
