internal import CIDAX
import Darwin

/// Which of IDA's item collections a directory tree organises.
public enum DirectoryKind: Int32, Sendable {
    case localTypes = 0
    case functions = 1
    case names = 2
    case imports = 3
    case idaPlaceBookmarks = 4
    case breakpoints = 5
    case localTypeBookmarks = 6
    case snippets = 7
}

/// Whether an entry is a folder or one of the collection's items.
public enum DirectoryEntryKind: Int32, Sendable {
    case directory = 0
    case item = 1
}

/// One node in a directory tree.
public struct DirectoryEntry: Sendable {
    public let path: String
    public let name: String
    public let displayName: String
    public let attributes: String
    public let kind: DirectoryEntryKind

    init(raw: IdaxDirectoryEntry) {
        // The entry owns its strings; the caller frees the whole struct.
        self.path = borrowCString(raw.path)
        self.name = borrowCString(raw.name)
        self.displayName = borrowCString(raw.display_name)
        self.attributes = borrowCString(raw.attributes)
        self.kind = DirectoryEntryKind(rawValue: raw.entry_kind) ?? .item
    }
}

/// One path that a bulk operation could not process.
public struct DirectoryBulkFailure: Sendable {
    /// Index of the offending path in the request, so a caller can correlate
    /// the failure with what it asked for.
    public let inputIndex: Int
    public let path: String
    public let operationError: Int32
    public let message: String

    init(raw: IdaxDirectoryBulkFailure) {
        self.inputIndex = raw.input_index
        self.path = borrowCString(raw.path)
        self.operationError = raw.operation_error
        self.message = borrowCString(raw.message)
    }
}

/// Outcome of a bulk move or remove.
///
/// Bulk operations are partial by design: some paths can succeed while others
/// fail, so the result is a report rather than a thrown error. Check
/// ``failures`` before assuming everything landed.
public struct DirectoryBulkReport: Sendable {
    public let affectedPaths: [String]
    public let failures: [DirectoryBulkFailure]

    public var succeededEntirely: Bool { failures.isEmpty }

    init(raw: IdaxDirectoryBulkReport) {
        if let paths = raw.affected_paths, raw.affected_paths_count > 0 {
            self.affectedPaths = UnsafeBufferPointer(
                start: paths, count: raw.affected_paths_count
            ).map { borrowCString($0) }
        } else {
            self.affectedPaths = []
        }
        if let failures = raw.failures, raw.failures_count > 0 {
            self.failures = UnsafeBufferPointer(
                start: failures, count: raw.failures_count
            ).map(DirectoryBulkFailure.init(raw:))
        } else {
            self.failures = []
        }
    }
}

/// The folder tree IDA keeps over one of its item collections.
///
/// A tree is identified by its ``kind`` alone and holds no native state, so it
/// is an ordinary value. Not every collection supports ordering — check
/// ``isOrderable()`` before using ``rank(of:)`` or ``changeRank(of:by:)``.
public struct DirectoryTree: Sendable {
    public let kind: DirectoryKind

    private init(validatedKind: DirectoryKind) {
        self.kind = validatedKind
    }

    /// Opens the tree over `kind`.
    public static func open(_ kind: DirectoryKind) throws(IDAError) -> DirectoryTree {
        try checkStatus(idax_directory_open(kind.rawValue), "directory.open")
        return DirectoryTree(validatedKind: kind)
    }

    /// Whether this collection supports explicit ordering.
    public func isOrderable() throws(IDAError) -> Bool {
        try withOutput("directory.isOrderable", Int32(0)) {
            idax_directory_is_orderable(kind.rawValue, $0)
        } != 0
    }

    // MARK: - Navigation

    /// The tree's current working directory.
    public func currentDirectory() throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(
            idax_directory_current_directory(kind.rawValue, &out),
            "directory.currentDirectory"
        )
        return takeCString(out)
    }

    /// Changes the tree's current working directory.
    public func changeDirectory(to path: String) throws(IDAError) {
        try checkStatus(
            idax_directory_change_directory(kind.rawValue, path),
            "directory.changeDirectory"
        )
    }

    /// Resolves `path` against the current working directory.
    public func absolutePath(of path: String) throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(
            idax_directory_absolute_path(kind.rawValue, path, &out),
            "directory.absolutePath"
        )
        return takeCString(out)
    }

    /// Whether `path` exists in this tree.
    public func contains(_ path: String) throws(IDAError) -> Bool {
        try withOutput("directory.contains", Int32(0)) {
            idax_directory_contains(kind.rawValue, path, $0)
        } != 0
    }

    // MARK: - Reading

    /// The entry at `path`.
    public func entry(at path: String) throws(IDAError) -> DirectoryEntry {
        var raw = IdaxDirectoryEntry()
        try checkStatus(
            idax_directory_entry(kind.rawValue, path, &raw),
            "directory.entry"
        )
        defer { idax_directory_entry_free(&raw) }
        return DirectoryEntry(raw: raw)
    }

    /// Direct children of `path`.
    public func children(of path: String) throws(IDAError) -> [DirectoryEntry] {
        try readEntries("directory.children") {
            idax_directory_children(kind.rawValue, path, $0, $1)
        }
    }

    /// Everything at or beneath `path`.
    public func snapshot(of path: String) throws(IDAError) -> [DirectoryEntry] {
        try readEntries("directory.snapshot") {
            idax_directory_snapshot(kind.rawValue, path, $0, $1)
        }
    }

    /// Items whose name matches `pattern`.
    public func findItems(matching pattern: String) throws(IDAError) -> [DirectoryEntry] {
        try readEntries("directory.findItems") {
            idax_directory_find_items(kind.rawValue, pattern, $0, $1)
        }
    }

    // MARK: - Structure

    /// Creates a directory at `path`.
    public func createDirectory(at path: String) throws(IDAError) {
        try checkStatus(
            idax_directory_create_directory(kind.rawValue, path),
            "directory.createDirectory"
        )
    }

    /// Removes the directory at `path`.
    public func removeDirectory(at path: String) throws(IDAError) {
        try checkStatus(
            idax_directory_remove_directory(kind.rawValue, path),
            "directory.removeDirectory"
        )
    }

    /// Attaches an existing collection item to the tree.
    public func link(_ path: String) throws(IDAError) {
        try checkStatus(idax_directory_link(kind.rawValue, path), "directory.link")
    }

    /// Detaches an item from the tree without deleting the item itself.
    public func unlink(_ path: String) throws(IDAError) {
        try checkStatus(idax_directory_unlink(kind.rawValue, path), "directory.unlink")
    }

    /// Renames an entry.
    public func rename(from source: String, to destination: String) throws(IDAError) {
        try checkStatus(
            idax_directory_rename(kind.rawValue, source, destination),
            "directory.rename"
        )
    }

    /// Collapses a shared name prefix beneath `path` into a directory level.
    public func foldCommonPrefix(at path: String) throws(IDAError) {
        try checkStatus(
            idax_directory_fold_common_prefix(kind.rawValue, path),
            "directory.foldCommonPrefix"
        )
    }

    // MARK: - Ordering

    /// Whether `path` uses natural (as opposed to explicit) ordering.
    public func hasNaturalOrder(at path: String) throws(IDAError) -> Bool {
        try withOutput("directory.hasNaturalOrder", Int32(0)) {
            idax_directory_has_natural_order(kind.rawValue, path, $0)
        } != 0
    }

    /// Switches `path` between natural and explicit ordering.
    public func setNaturalOrder(at path: String, enabled: Bool) throws(IDAError) {
        try checkStatus(
            idax_directory_set_natural_order(kind.rawValue, path, enabled ? 1 : 0),
            "directory.setNaturalOrder"
        )
    }

    /// Position of `path` among its siblings.
    public func rank(of path: String) throws(IDAError) -> Int {
        try withOutput("directory.rank", Int(0)) {
            idax_directory_rank(kind.rawValue, path, $0)
        }
    }

    /// Moves `path` `delta` positions among its siblings.
    public func changeRank(of path: String, by delta: Int) throws(IDAError) {
        try checkStatus(
            idax_directory_change_rank(kind.rawValue, path, delta),
            "directory.changeRank"
        )
    }

    // MARK: - Bulk operations

    /// Moves several paths under `destination`.
    ///
    /// - Parameter destinationRank: insert at this position rather than
    ///   appending.
    /// - Returns: a report; individual paths can fail without the call throwing.
    @discardableResult
    public func move(
        _ paths: [String],
        to destination: String,
        destinationRank: Int? = nil
    ) throws(IDAError) -> DirectoryBulkReport {
        try bulk("directory.move") { pathPointers, count, report in
            idax_directory_move(
                kind.rawValue, pathPointers, count, destination,
                destinationRank == nil ? 0 : 1, destinationRank ?? 0, report
            )
        } paths: { paths }
    }

    /// Removes several paths.
    ///
    /// - Returns: a report; individual paths can fail without the call throwing.
    @discardableResult
    public func remove(_ paths: [String]) throws(IDAError) -> DirectoryBulkReport {
        try bulk("directory.remove") { pathPointers, count, report in
            idax_directory_remove(kind.rawValue, pathPointers, count, report)
        } paths: { paths }
    }

    // MARK: - Shared plumbing

    private func readEntries(
        _ fallback: String,
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<IdaxDirectoryEntry>?>,
            UnsafeMutablePointer<Int>
        ) -> Int32
    ) throws(IDAError) -> [DirectoryEntry] {
        var pointer: UnsafeMutablePointer<IdaxDirectoryEntry>? = nil
        var count: Int = 0
        try checkStatus(body(&pointer, &count), fallback)
        defer { idax_directory_entries_free(pointer, count) }
        guard let pointer, count > 0 else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).map(DirectoryEntry.init(raw:))
    }

    private func bulk(
        _ fallback: String,
        _ body: (
            UnsafePointer<UnsafePointer<CChar>?>?, Int,
            UnsafeMutablePointer<IdaxDirectoryBulkReport>
        ) -> Int32,
        paths: () -> [String]
    ) throws(IDAError) -> DirectoryBulkReport {
        let pathList = paths()
        let cStrings = pathList.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }

        var report = IdaxDirectoryBulkReport()
        let status = cStrings.withUnsafeBufferPointer { buffer in
            buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
                body(rebound.baseAddress, rebound.count, &report)
            }
        }
        try checkStatus(status, fallback)
        defer { idax_directory_bulk_report_free(&report) }
        return DirectoryBulkReport(raw: report)
    }
}
