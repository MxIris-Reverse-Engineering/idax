/// Isolation for every call into the IDA runtime.
///
/// `idalib` requires that all of its calls happen on the thread that
/// initialised it, and in practice that thread must be the process main
/// thread: IDAPython's initialisation emits a synchronous warning that enters
/// IDA's own main-thread execution path and waits on a semaphore, so calling
/// from anywhere else deadlocks rather than failing cleanly. The Rust bindings
/// hit exactly this and were forced to abandon the standard test harness for a
/// custom one that runs every call on process main.
///
/// `IDAActor` is therefore an alias for `MainActor` rather than an independent
/// global actor. The alias exists for two reasons:
///
/// - It states the *reason* for the isolation at every declaration site. A
///   headless command-line tool has no user interface, and `@MainActor` would
///   suggest one; `@IDAActor` says "this is an IDA constraint".
/// - If IDA ever relaxes the requirement, the constraint is named in one place.
///   Note that this would still not be a drop-in substitution — downstream code
///   annotated `@IDAActor` is genuinely `MainActor`-isolated today.
///
/// The module sets `defaultIsolation` to `MainActor` in `Package.swift`, so
/// declarations are isolated without annotation. Write `@IDAActor` explicitly
/// only where the isolation is worth pointing out, and `nonisolated` where a
/// declaration genuinely does not touch the runtime — most importantly on the
/// C callback trampolines, which IDA invokes directly.
///
/// ## Calling from a callback
///
/// IDA invokes registered callbacks synchronously on its own thread. A
/// trampoline is therefore `nonisolated` and recovers the isolation that is
/// already factually in effect:
///
/// ```swift
/// private func trampoline(context: UnsafeMutableRawPointer?) {
///     MainActor.assumeIsolated {
///         // ... call the user's isolated closure
///     }
/// }
/// ```
///
/// `assumeIsolated` asserts rather than hops, which is the behaviour we want:
/// a callback arriving off the main thread is a bug to surface, not a
/// condition to paper over by scheduling.
public typealias IDAActor = MainActor

/// Runs `body` with `IDAActor` isolation recovered, for use inside a C callback
/// trampoline.
///
/// A trampoline has to be `nonisolated` — a C function pointer can only be
/// formed from one — but the user's handler is `@IDAActor`, so the isolation has
/// to be reasserted before calling it. IDA invokes the callback synchronously on
/// the thread that initialised idalib, so the assertion holds; if it ever does
/// not, this traps, which is the correct outcome for a callback arriving on a
/// thread from which no IDA call is legal.
///
/// Wrap only the part that touches the handler. The surrounding pointer
/// unwrapping is genuinely `nonisolated`, and wrapping it too would assert that
/// it needs the main thread, which is not true.
/// ## Calling from a nonisolated entry point you control
///
/// Some protocols force `nonisolated` on their requirements —
/// `ParsableCommand.run()` is the one this package's own tool hits. When the
/// entry point is nevertheless known to be on the main thread, as it is for a
/// command-line `main`, wrap the body rather than restructuring around it:
///
/// ```swift
/// public mutating func run() throws {
///     try onIDAThread { try performWork() }
/// }
/// ```
///
/// Do not reach for this to silence a diagnostic on a thread you have not
/// established. It traps when wrong, which is better than corrupting a database,
/// but the trap is a poor substitute for knowing.
@inline(__always)
public nonisolated func onIDAThread<CallbackResult: Sendable>(
    _ body: @IDAActor () throws -> CallbackResult
) rethrows -> CallbackResult {
    try MainActor.assumeIsolated(body)
}
