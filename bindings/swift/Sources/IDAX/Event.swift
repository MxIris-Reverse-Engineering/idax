internal import CIDAX

/// RAII event subscription token. Unsubscribes on deinit.
public struct EventSubscription: ~Copyable, @unchecked Sendable {
    private let token: UInt64
    private let context: UnsafeMutableRawPointer

    init(token: UInt64, context: UnsafeMutableRawPointer) {
        self.token = token
        self.context = context
    }

    deinit {
        idax_event_unsubscribe(token)
        Unmanaged<AnyObject>.fromOpaque(context).release()
    }

    public consuming func cancel() {
        idax_event_unsubscribe(token)
        Unmanaged<AnyObject>.fromOpaque(context).release()
        discard self
    }
}

/// IDB event subscriptions.
///
/// Mirrors C++ `ida::event`. Callbacks are stored in a box to bridge
/// Swift closures through the C function-pointer ABI.
public enum Event {

    public static func onRenamed(
        _ handler: @escaping @IDAActor (Address, String, String) -> Void
    ) throws(IDAError) -> EventSubscription {
        let box = RenamedBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_event_on_renamed(renamedTrampoline, ctx, &token),
                "event.onRenamed"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return EventSubscription(token: token, context: ctx)
    }

    public static func onFunctionAdded(
        _ handler: @escaping @IDAActor (Address) -> Void
    ) throws(IDAError) -> EventSubscription {
        let box = AddressBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_event_on_function_added(functionAddedTrampoline, ctx, &token),
                "event.onFunctionAdded"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return EventSubscription(token: token, context: ctx)
    }

    public static func onFunctionDeleted(
        _ handler: @escaping @IDAActor (Address) -> Void
    ) throws(IDAError) -> EventSubscription {
        let box = AddressBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_event_on_function_deleted(functionDeletedTrampoline, ctx, &token),
                "event.onFunctionDeleted"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return EventSubscription(token: token, context: ctx)
    }

    public static func onBytePatched(
        _ handler: @escaping @IDAActor (Address, UInt32) -> Void
    ) throws(IDAError) -> EventSubscription {
        let box = BytePatchedBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_event_on_byte_patched(bytePatchedTrampoline, ctx, &token),
                "event.onBytePatched"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return EventSubscription(token: token, context: ctx)
    }

    public static func unsubscribe(token: UInt64) {
        idax_event_unsubscribe(token)
    }

    public static func subscribe(
        kind: Int32,
        handler: @escaping @IDAActor (Int32, UInt64, UInt64) -> Void
    ) throws(IDAError) -> EventSubscription {
        let box = GenericEventBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_event_subscribe(kind, genericEventTrampoline, ctx, &token),
                "event.subscribe"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return EventSubscription(token: token, context: ctx)
    }

    public static func onSegmentAdded(
        _ handler: @escaping @IDAActor (Address) -> Void
    ) throws(IDAError) -> EventSubscription {
        let box = AddressBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_event_on_segment_added(segmentAddedTrampoline, ctx, &token),
                "event.onSegmentAdded"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return EventSubscription(token: token, context: ctx)
    }

    public static func onSegmentDeleted(
        _ handler: @escaping @IDAActor (Address, Address) -> Void
    ) throws(IDAError) -> EventSubscription {
        let box = SegmentDeletedBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_event_on_segment_deleted(segmentDeletedTrampoline, ctx, &token),
                "event.onSegmentDeleted"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return EventSubscription(token: token, context: ctx)
    }

    public static func onCommentChanged(
        _ handler: @escaping @IDAActor (Address, Bool) -> Void
    ) throws(IDAError) -> EventSubscription {
        let box = CommentChangedBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_event_on_comment_changed(commentChangedTrampoline, ctx, &token),
                "event.onCommentChanged"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return EventSubscription(token: token, context: ctx)
    }

    public static func onEvent(
        _ handler: @escaping @IDAActor (IDAEvent) -> Void
    ) throws(IDAError) -> EventSubscription {
        let box = EventExBox(handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_event_on_event(eventExTrampoline, ctx, &token),
                "event.onEvent"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return EventSubscription(token: token, context: ctx)
    }

    public static func onEventFiltered(
        filter: @escaping @IDAActor (IDAEvent) -> Bool,
        handler: @escaping @IDAActor (IDAEvent) -> Void
    ) throws(IDAError) -> EventSubscription {
        let box = EventFilteredBox(filter: filter, handler: handler)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        var token: UInt64 = 0
        do {
            try checkStatus(
                idax_event_on_event_filtered(eventFilterTrampoline, eventFilteredHandlerTrampoline, ctx, &token),
                "event.onEventFiltered"
            )
        } catch {
            Unmanaged<AnyObject>.fromOpaque(ctx).release()
            throw error
        }
        return EventSubscription(token: token, context: ctx)
    }
}

// MARK: - Callback boxes and trampolines

private nonisolated final class RenamedBox {
    let handler: @IDAActor (Address, String, String) -> Void
    init(handler: @escaping @IDAActor (Address, String, String) -> Void) { self.handler = handler }
}

private nonisolated final class AddressBox {
    let handler: @IDAActor (Address) -> Void
    init(handler: @escaping @IDAActor (Address) -> Void) { self.handler = handler }
}

private nonisolated final class BytePatchedBox {
    let handler: @IDAActor (Address, UInt32) -> Void
    init(handler: @escaping @IDAActor (Address, UInt32) -> Void) { self.handler = handler }
}

private nonisolated func renamedTrampoline(
    ctx: UnsafeMutableRawPointer?,
    address: UInt64,
    newName: UnsafePointer<CChar>?,
    oldName: UnsafePointer<CChar>?
) {
    nonisolated(unsafe) let ctx = ctx
    nonisolated(unsafe) let newName = newName
    nonisolated(unsafe) let oldName = oldName
    onIDAThread {
        guard let ctx else { return }
        let box = Unmanaged<RenamedBox>.fromOpaque(ctx).takeUnretainedValue()
        let nn = newName.map { String(cString: $0) } ?? ""
        let on = oldName.map { String(cString: $0) } ?? ""
        box.handler(address, nn, on)
    }
}

private nonisolated func functionAddedTrampoline(ctx: UnsafeMutableRawPointer?, entry: UInt64) {
    nonisolated(unsafe) let ctx = ctx
    onIDAThread {
        guard let ctx else { return }
        let box = Unmanaged<AddressBox>.fromOpaque(ctx).takeUnretainedValue()
        box.handler(entry)
    }
}

private nonisolated func functionDeletedTrampoline(ctx: UnsafeMutableRawPointer?, entry: UInt64) {
    nonisolated(unsafe) let ctx = ctx
    onIDAThread {
        guard let ctx else { return }
        let box = Unmanaged<AddressBox>.fromOpaque(ctx).takeUnretainedValue()
        box.handler(entry)
    }
}

private nonisolated func bytePatchedTrampoline(ctx: UnsafeMutableRawPointer?, address: UInt64, oldValue: UInt32) {
    nonisolated(unsafe) let ctx = ctx
    onIDAThread {
        guard let ctx else { return }
        let box = Unmanaged<BytePatchedBox>.fromOpaque(ctx).takeUnretainedValue()
        box.handler(address, oldValue)
    }
}

// MARK: - New callback boxes and trampolines

private nonisolated final class GenericEventBox {
    let handler: @IDAActor (Int32, UInt64, UInt64) -> Void
    init(handler: @escaping @IDAActor (Int32, UInt64, UInt64) -> Void) { self.handler = handler }
}

private nonisolated func genericEventTrampoline(ctx: UnsafeMutableRawPointer?, kind: Int32, addr: UInt64, secondary: UInt64) {
    nonisolated(unsafe) let ctx = ctx
    onIDAThread {
        guard let ctx else { return }
        let box = Unmanaged<GenericEventBox>.fromOpaque(ctx).takeUnretainedValue()
        box.handler(kind, addr, secondary)
    }
}

private nonisolated func segmentAddedTrampoline(ctx: UnsafeMutableRawPointer?, start: UInt64) {
    nonisolated(unsafe) let ctx = ctx
    onIDAThread {
        guard let ctx else { return }
        let box = Unmanaged<AddressBox>.fromOpaque(ctx).takeUnretainedValue()
        box.handler(start)
    }
}

private nonisolated final class SegmentDeletedBox {
    let handler: @IDAActor (Address, Address) -> Void
    init(handler: @escaping @IDAActor (Address, Address) -> Void) { self.handler = handler }
}

private nonisolated func segmentDeletedTrampoline(ctx: UnsafeMutableRawPointer?, start: UInt64, end: UInt64) {
    nonisolated(unsafe) let ctx = ctx
    onIDAThread {
        guard let ctx else { return }
        let box = Unmanaged<SegmentDeletedBox>.fromOpaque(ctx).takeUnretainedValue()
        box.handler(start, end)
    }
}

private nonisolated final class CommentChangedBox {
    let handler: @IDAActor (Address, Bool) -> Void
    init(handler: @escaping @IDAActor (Address, Bool) -> Void) { self.handler = handler }
}

private nonisolated func commentChangedTrampoline(ctx: UnsafeMutableRawPointer?, address: UInt64, repeatable: Int32) {
    nonisolated(unsafe) let ctx = ctx
    onIDAThread {
        guard let ctx else { return }
        let box = Unmanaged<CommentChangedBox>.fromOpaque(ctx).takeUnretainedValue()
        box.handler(address, repeatable != 0)
    }
}

/// Swift representation of a raw IDB event.
public struct IDAEvent: Sendable {
    public let kind: Int32
    public let address: Address
    public let secondaryAddress: Address
    public let newName: String
    public let oldName: String
    public let oldValue: UInt32
    public let repeatable: Bool
}

private nonisolated func makeIDAEvent(_ raw: UnsafePointer<IdaxEvent>) -> IDAEvent {
    IDAEvent(
        kind: raw.pointee.kind,
        address: raw.pointee.address,
        secondaryAddress: raw.pointee.secondary_address,
        newName: raw.pointee.new_name.map { String(cString: $0) } ?? "",
        oldName: raw.pointee.old_name.map { String(cString: $0) } ?? "",
        oldValue: raw.pointee.old_value,
        repeatable: raw.pointee.repeatable != 0
    )
}

private nonisolated final class EventExBox {
    let handler: @IDAActor (IDAEvent) -> Void
    init(handler: @escaping @IDAActor (IDAEvent) -> Void) { self.handler = handler }
}

private nonisolated func eventExTrampoline(ctx: UnsafeMutableRawPointer?, event: UnsafePointer<IdaxEvent>?) {
    nonisolated(unsafe) let ctx = ctx
    nonisolated(unsafe) let event = event
    onIDAThread {
        guard let ctx, let event else { return }
        let box = Unmanaged<EventExBox>.fromOpaque(ctx).takeUnretainedValue()
        box.handler(makeIDAEvent(event))
    }
}

private nonisolated final class EventFilteredBox {
    let filter: @IDAActor (IDAEvent) -> Bool
    let handler: @IDAActor (IDAEvent) -> Void
    init(filter: @escaping @IDAActor (IDAEvent) -> Bool, handler: @escaping @IDAActor (IDAEvent) -> Void) {
        self.filter = filter
        self.handler = handler
    }
}

private nonisolated func eventFilterTrampoline(ctx: UnsafeMutableRawPointer?, event: UnsafePointer<IdaxEvent>?) -> Int32 {
    nonisolated(unsafe) let ctx = ctx
    nonisolated(unsafe) let event = event
    return onIDAThread {
        guard let ctx, let event else { return 0 }
        let box = Unmanaged<EventFilteredBox>.fromOpaque(ctx).takeUnretainedValue()
        return box.filter(makeIDAEvent(event)) ? 1 : 0
    }
}

private nonisolated func eventFilteredHandlerTrampoline(ctx: UnsafeMutableRawPointer?, event: UnsafePointer<IdaxEvent>?) {
    nonisolated(unsafe) let ctx = ctx
    nonisolated(unsafe) let event = event
    onIDAThread {
        guard let ctx, let event else { return }
        let box = Unmanaged<EventFilteredBox>.fromOpaque(ctx).takeUnretainedValue()
        box.handler(makeIDAEvent(event))
    }
}
