internal import CIDAX
import Darwin

/// A saved address with a description, occupying one of IDA's bookmark slots.
public struct Bookmark: Sendable {
    public let address: Address
    public let slot: UInt32
    public let text: String

    /// The number of bookmark slots IDA provides.
    public static let slotCount: UInt32 = 1024

    init(raw: IdaxBookmark) {
        self.address = raw.address
        self.slot = raw.slot
        // The containing struct owns the string; `idax_bookmark_free` releases it.
        self.text = borrowCString(raw.description)
    }

    /// Every bookmark in the database, in slot order.
    public static func all() throws(IDAError) -> [Bookmark] {
        var pointer: UnsafeMutablePointer<IdaxBookmark>? = nil
        var count: Int = 0
        try checkStatus(idax_bookmark_all(&pointer, &count), "bookmark.all")
        guard let pointer, count > 0 else {
            free(pointer)
            return []
        }
        defer {
            for index in 0..<count {
                idax_bookmark_free(pointer.advanced(by: index))
            }
            free(pointer)
        }
        return UnsafeBufferPointer(start: pointer, count: count).map(Bookmark.init(raw:))
    }

    /// The bookmark at `address`, or `nil` when there is none.
    public static func at(_ address: Address) throws(IDAError) -> Bookmark? {
        var raw = IdaxBookmark()
        var hasValue: Int32 = 0
        try checkStatus(idax_bookmark_at(address, &raw, &hasValue), "bookmark.at")
        guard hasValue != 0 else { return nil }
        defer { idax_bookmark_free(&raw) }
        return Bookmark(raw: raw)
    }

    /// The bookmark occupying `slot`, or `nil` when the slot is empty.
    public static func at(slot: UInt32) throws(IDAError) -> Bookmark? {
        var raw = IdaxBookmark()
        var hasValue: Int32 = 0
        try checkStatus(idax_bookmark_at_slot(slot, &raw, &hasValue), "bookmark.atSlot")
        guard hasValue != 0 else { return nil }
        defer { idax_bookmark_free(&raw) }
        return Bookmark(raw: raw)
    }

    /// Places a bookmark at `address`.
    ///
    /// - Parameter slot: the slot to occupy; when `nil`, IDA picks a free one.
    /// - Returns: the bookmark as stored, with the slot IDA actually used.
    @discardableResult
    public static func set(
        at address: Address,
        text: String,
        slot: UInt32? = nil
    ) throws(IDAError) -> Bookmark {
        var raw = IdaxBookmark()
        try checkStatus(
            idax_bookmark_set(address, text, slot == nil ? 0 : 1, slot ?? 0, &raw),
            "bookmark.set"
        )
        defer { idax_bookmark_free(&raw) }
        return Bookmark(raw: raw)
    }

    /// Removes the bookmark at `address`.
    ///
    /// - Returns: whether a bookmark was actually removed.
    @discardableResult
    public static func remove(at address: Address) throws(IDAError) -> Bool {
        try withOutput("bookmark.remove", Int32(0)) {
            idax_bookmark_remove(address, $0)
        } != 0
    }

    /// Clears `slot`.
    ///
    /// - Returns: whether the slot had held a bookmark.
    @discardableResult
    public static func remove(slot: UInt32) throws(IDAError) -> Bool {
        try withOutput("bookmark.removeSlot", Int32(0)) {
            idax_bookmark_remove_slot(slot, $0)
        } != 0
    }
}
