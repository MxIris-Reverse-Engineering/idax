internal import CIDAX
import Darwin

/// One position in a navigation history.
///
/// `channel` names the view the position belongs to — IDA keeps a separate
/// current position per channel while sharing one history — and `metadata`
/// carries whatever the producer of the entry attached to it.
public struct NavigationEntry: Sendable, Equatable {
    public let address: Address
    public let channel: String
    public let metadata: String

    /// - Parameters:
    ///   - address: must not be ``BadAddress``.
    ///   - channel: must not be empty, and must not start with IDAX's reserved
    ///     prefix. Both are rejected by C++ `validate_entry`.
    ///   - metadata: may be empty; only an embedded NUL is rejected.
    public init(address: Address, channel: String, metadata: String = "") {
        self.address = address
        self.channel = channel
        self.metadata = metadata
    }

    init(raw: IdaxNavigationEntry) {
        self.address = raw.address
        // The entry owns its strings; `idax_navigation_entry_free` releases them.
        self.channel = borrowCString(raw.channel)
        self.metadata = borrowCString(raw.metadata)
    }
}

/// Borrow a Swift entry as the C struct the shim expects.
///
/// The shim treats the pointer as read-only, so the strings can be borrowed for
/// the duration of the call rather than copied.
private func withRawEntry<CallResult>(
    _ entry: NavigationEntry,
    _ body: (UnsafePointer<IdaxNavigationEntry>) -> CallResult
) -> CallResult {
    entry.channel.withCString { channelPointer in
        entry.metadata.withCString { metadataPointer in
            var raw = IdaxNavigationEntry()
            raw.address = entry.address
            raw.channel = UnsafeMutablePointer(mutating: channelPointer)
            raw.metadata = UnsafeMutablePointer(mutating: metadataPointer)
            return withUnsafePointer(to: &raw) { body($0) }
        }
    }
}

/// Consume an entry the shim allocated.
private func takeEntry(_ raw: inout IdaxNavigationEntry) -> NavigationEntry {
    defer { idax_navigation_entry_free(&raw) }
    return NavigationEntry(raw: raw)
}

/// A named address-navigation history, as IDA's back and forward commands use.
///
/// Move-only: the handle owns an IDA-side history and releases it on `deinit`.
/// Opening the same name twice returns the same underlying history — check
/// ``wasCreated()`` to tell whether this call created it.
public struct NavigationHistory: ~Copyable {
    private let handle: IdaxNavigationHistoryHandle

    private init(handle: IdaxNavigationHistoryHandle) {
        self.handle = handle
    }

    /// Opens the history called `name`, creating it when it does not exist.
    ///
    /// - Parameter initial: the position to seed a newly created history with.
    ///   Required — C++ takes it by reference, and the shim rejects a null
    ///   pointer — and ignored when the history already exists.
    public static func open(
        name: String,
        initial: NavigationEntry
    ) throws(IDAError) -> NavigationHistory {
        var handle: IdaxNavigationHistoryHandle? = nil
        try checkStatus(
            withRawEntry(initial) { idax_navigation_history_open(name, $0, &handle) },
            "navigation.open"
        )
        guard let handle else {
            throw IDAError(
                category: .internal,
                code: 0,
                message: "navigation.open reported success but returned no handle"
            )
        }
        return NavigationHistory(handle: handle)
    }

    deinit {
        idax_navigation_history_free(handle)
    }

    /// The name this history was opened under.
    public func name() throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(idax_navigation_history_name(handle, &out), "navigation.name")
        return takeCString(out)
    }

    /// Whether ``open(name:initial:)`` created this history rather than finding it.
    public func wasCreated() throws(IDAError) -> Bool {
        try withOutput("navigation.wasCreated", Int32(0)) {
            idax_navigation_history_created(handle, $0)
        } != 0
    }

    /// Every entry, oldest first.
    public func entries() throws(IDAError) -> [NavigationEntry] {
        var pointer: UnsafeMutablePointer<IdaxNavigationEntry>? = nil
        var count: Int = 0
        try checkStatus(
            idax_navigation_history_entries(handle, &pointer, &count),
            "navigation.entries"
        )
        guard let pointer, count > 0 else {
            idax_navigation_entries_free(pointer, count)
            return []
        }
        defer { idax_navigation_entries_free(pointer, count) }
        return UnsafeBufferPointer(start: pointer, count: count).map(NavigationEntry.init(raw:))
    }

    /// How many entries the history holds.
    public func count() throws(IDAError) -> Int {
        try withOutput("navigation.count", Int(0)) {
            idax_navigation_history_size(handle, $0)
        }
    }

    /// Index of the current position within ``entries()``.
    public func currentIndex() throws(IDAError) -> Int {
        try withOutput("navigation.currentIndex", Int(0)) {
            idax_navigation_history_index(handle, $0)
        }
    }

    /// The current position.
    public func current() throws(IDAError) -> NavigationEntry {
        var raw = IdaxNavigationEntry()
        try checkStatus(idax_navigation_history_current(handle, &raw), "navigation.current")
        return takeEntry(&raw)
    }

    /// The current position for one channel, or `nil` when that channel has none.
    public func current(forChannel channel: String) throws(IDAError) -> NavigationEntry? {
        var raw = IdaxNavigationEntry()
        var hasValue: Int32 = 0
        try checkStatus(
            idax_navigation_history_current_for(handle, channel, &raw, &hasValue),
            "navigation.currentForChannel"
        )
        guard hasValue != 0 else { return nil }
        return takeEntry(&raw)
    }

    /// The current position of every channel that has one.
    public func allCurrent() throws(IDAError) -> [NavigationEntry] {
        var pointer: UnsafeMutablePointer<IdaxNavigationEntry>? = nil
        var count: Int = 0
        try checkStatus(
            idax_navigation_history_all_current(handle, &pointer, &count),
            "navigation.allCurrent"
        )
        guard let pointer, count > 0 else {
            idax_navigation_entries_free(pointer, count)
            return []
        }
        defer { idax_navigation_entries_free(pointer, count) }
        return UnsafeBufferPointer(start: pointer, count: count).map(NavigationEntry.init(raw:))
    }

    /// Moves the current position.
    ///
    /// - Parameter recordInHistory: append the move to the history, as a user
    ///   jump would. Pass `false` to reposition without leaving a trace.
    public func setCurrent(
        _ entry: NavigationEntry,
        recordInHistory: Bool = true
    ) throws(IDAError) {
        try checkStatus(
            withRawEntry(entry) {
                idax_navigation_history_set_current(handle, $0, recordInHistory ? 1 : 0)
            },
            "navigation.setCurrent"
        )
    }

    /// Appends `entry` and makes it current.
    ///
    /// - Returns: the entry as stored.
    @discardableResult
    public func push(_ entry: NavigationEntry) throws(IDAError) -> NavigationEntry {
        var raw = IdaxNavigationEntry()
        try checkStatus(
            withRawEntry(entry) { idax_navigation_history_push(handle, $0, &raw) },
            "navigation.push"
        )
        return takeEntry(&raw)
    }

    /// Makes the entry at `index` current.
    @discardableResult
    public func seek(to index: Int) throws(IDAError) -> NavigationEntry {
        var raw = IdaxNavigationEntry()
        try checkStatus(idax_navigation_history_seek(handle, index, &raw), "navigation.seek")
        return takeEntry(&raw)
    }

    /// Steps back `count` positions.
    ///
    /// - Returns: the new current entry, or `nil` when already at the oldest
    ///   position. Running out of history is not an error.
    @discardableResult
    public func back(_ count: Int = 1) throws(IDAError) -> NavigationEntry? {
        var raw = IdaxNavigationEntry()
        var hasValue: Int32 = 0
        try checkStatus(
            idax_navigation_history_back(handle, count, &raw, &hasValue),
            "navigation.back"
        )
        guard hasValue != 0 else { return nil }
        return takeEntry(&raw)
    }

    /// Steps forward `count` positions.
    ///
    /// - Returns: the new current entry, or `nil` when already at the newest
    ///   position. Running out of history is not an error.
    @discardableResult
    public func forward(_ count: Int = 1) throws(IDAError) -> NavigationEntry? {
        var raw = IdaxNavigationEntry()
        var hasValue: Int32 = 0
        try checkStatus(
            idax_navigation_history_forward(handle, count, &raw, &hasValue),
            "navigation.forward"
        )
        guard hasValue != 0 else { return nil }
        return takeEntry(&raw)
    }

    /// Overwrites the entry at `index`.
    public func replace(at index: Int, with entry: NavigationEntry) throws(IDAError) {
        try checkStatus(
            withRawEntry(entry) { idax_navigation_history_replace(handle, index, $0) },
            "navigation.replace"
        )
    }

    /// Discards every entry and seeds the emptied history with `newTip`.
    ///
    /// `newTip` is required for the same reason as ``open(name:initial:)``'s
    /// `initial`: a history always has a current position.
    public func clear(newTip: NavigationEntry) throws(IDAError) {
        try checkStatus(
            withRawEntry(newTip) { idax_navigation_history_clear(handle, $0) },
            "navigation.clear"
        )
    }
}
