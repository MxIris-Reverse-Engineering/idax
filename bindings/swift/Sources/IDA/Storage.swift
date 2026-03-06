import CIDA

/// Persistent key-value storage node (netnode abstraction).
///
/// Reference type — `deinit` frees the underlying handle.
public final class StorageNode: @unchecked Sendable {
    let handle: IdaxNodeHandle

    init(_ handle: IdaxNodeHandle) {
        self.handle = handle
    }

    deinit {
        idax_storage_node_free(handle)
    }

    public static func open(name: String, create: Bool = false) throws(IDAError) -> StorageNode {
        var handle: IdaxNodeHandle?
        try checkStatus(
            name.withCString { idax_storage_node_open($0, create ? 1 : 0, &handle) },
            "storage.open"
        )
        guard let handle else {
            throw IDAError(category: .internal, code: 0, message: "nil handle after successful call")
        }
        return StorageNode(handle)
    }

    public static func open(id: UInt64) throws(IDAError) -> StorageNode {
        var handle: IdaxNodeHandle?
        try checkStatus(idax_storage_node_open_by_id(id, &handle), "storage.openByID")
        guard let handle else {
            throw IDAError(category: .internal, code: 0, message: "nil handle after successful call")
        }
        return StorageNode(handle)
    }

    public var id: UInt64 {
        get throws(IDAError) {
            try withOutput("storage.id", UInt64(0)) { idax_storage_node_id(handle, $0) }
        }
    }

    public var name: String {
        get throws(IDAError) {
            try withStringOutput("storage.name") { idax_storage_node_name(handle, $0) }
        }
    }

    // MARK: - Alt (integer values)

    public func altGet(index: UInt64, tag: UInt8 = UInt8(ascii: "A")) throws(IDAError) -> UInt64 {
        try withOutput("storage.altGet", UInt64(0)) { idax_storage_node_alt_get(handle, index, tag, $0) }
    }

    public func altSet(index: UInt64, value: UInt64, tag: UInt8 = UInt8(ascii: "A")) throws(IDAError) {
        try checkStatus(idax_storage_node_alt_set(handle, index, value, tag), "storage.altSet")
    }

    // MARK: - Hash (string values)

    public func hashGet(key: String, tag: UInt8 = UInt8(ascii: "H")) throws(IDAError) -> String {
        try withStringOutput("storage.hashGet") { out in
            key.withCString { idax_storage_node_hash_get(handle, $0, tag, out) }
        }
    }

    public func hashSet(key: String, value: String, tag: UInt8 = UInt8(ascii: "H")) throws(IDAError) {
        try checkStatus(
            key.withCString { k in
                value.withCString { v in
                    idax_storage_node_hash_set(handle, k, v, tag)
                }
            },
            "storage.hashSet"
        )
    }

    // MARK: - Blob (binary data)

    public func blobGet(index: UInt64, tag: UInt8 = UInt8(ascii: "B")) throws(IDAError) -> [UInt8] {
        var ptr: UnsafeMutablePointer<UInt8>? = nil
        var len: Int = 0
        try checkStatus(idax_storage_node_blob_get(handle, index, tag, &ptr, &len), "storage.blobGet")
        defer { idax_free_bytes(ptr) }
        guard let ptr, len > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ptr, count: len))
    }

    public func blobSet(index: UInt64, data: [UInt8], tag: UInt8 = UInt8(ascii: "B")) throws(IDAError) {
        try checkStatus(
            data.withUnsafeBufferPointer {
                idax_storage_node_blob_set(handle, index, $0.baseAddress, $0.count, tag)
            },
            "storage.blobSet"
        )
    }
}
