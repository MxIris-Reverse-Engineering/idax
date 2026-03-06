import CIDA

/// RAII event subscription token. Unsubscribes on deinit.
public final class EventSubscription: @unchecked Sendable {
    private let token: UInt64
    private let context: UnsafeMutableRawPointer
    private var active = true

    init(token: UInt64, context: UnsafeMutableRawPointer) {
        self.token = token
        self.context = context
    }

    deinit {
        if active {
            idax_event_unsubscribe(token)
            Unmanaged<AnyObject>.fromOpaque(context).release()
        }
    }

    public func cancel() {
        if active {
            idax_event_unsubscribe(token)
            Unmanaged<AnyObject>.fromOpaque(context).release()
            active = false
        }
    }
}

/// IDB event subscriptions.
///
/// Mirrors C++ `ida::event`. Callbacks are stored in a box to bridge
/// Swift closures through the C function-pointer ABI.
public enum Event {

    public static func onRenamed(
        _ handler: @escaping (Address, String, String) -> Void
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
        _ handler: @escaping (Address) -> Void
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
        _ handler: @escaping (Address) -> Void
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
        _ handler: @escaping (Address, UInt32) -> Void
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
}

// MARK: - Callback boxes and trampolines

private final class RenamedBox {
    let handler: (Address, String, String) -> Void
    init(handler: @escaping (Address, String, String) -> Void) { self.handler = handler }
}

private final class AddressBox {
    let handler: (Address) -> Void
    init(handler: @escaping (Address) -> Void) { self.handler = handler }
}

private final class BytePatchedBox {
    let handler: (Address, UInt32) -> Void
    init(handler: @escaping (Address, UInt32) -> Void) { self.handler = handler }
}

private func renamedTrampoline(
    ctx: UnsafeMutableRawPointer?,
    address: UInt64,
    newName: UnsafePointer<CChar>?,
    oldName: UnsafePointer<CChar>?
) {
    guard let ctx else { return }
    let box = Unmanaged<RenamedBox>.fromOpaque(ctx).takeUnretainedValue()
    let nn = newName.map { String(cString: $0) } ?? ""
    let on = oldName.map { String(cString: $0) } ?? ""
    box.handler(address, nn, on)
}

private func functionAddedTrampoline(ctx: UnsafeMutableRawPointer?, entry: UInt64) {
    guard let ctx else { return }
    let box = Unmanaged<AddressBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(entry)
}

private func functionDeletedTrampoline(ctx: UnsafeMutableRawPointer?, entry: UInt64) {
    guard let ctx else { return }
    let box = Unmanaged<AddressBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(entry)
}

private func bytePatchedTrampoline(ctx: UnsafeMutableRawPointer?, address: UInt64, oldValue: UInt32) {
    guard let ctx else { return }
    let box = Unmanaged<BytePatchedBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(address, oldValue)
}
