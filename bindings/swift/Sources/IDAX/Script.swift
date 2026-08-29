internal import CIDAX
import Darwin

/// What an IDC value holds.
public enum ScriptValueKind: Int32, Sendable {
    case integer = 0
    case floatingPoint = 1
    case object = 2
    case function = 3
    case string = 4
    case opaquePointer = 5
    case reference = 6
}

/// How far ``ScriptValue/dereference(mode:)`` follows a chain of references.
public enum ScriptDereferenceMode: Int32, Sendable {
    case once = 0
    case recursive = 1
}

/// One IDC value.
///
/// Move-only: the handle owns an IDA-side value and frees it on `deinit`.
/// Passing a value to a setter such as ``setAttribute(_:to:useHandler:)``
/// *borrows* it — C++ copies out of it, so the caller keeps ownership and can
/// go on using it. The one place ownership transfers is
/// ``ScriptArguments/append(_:)``.
public struct ScriptValue: ~Copyable {
    private let handle: IdaxScriptValueHandle

    private init(owning handle: IdaxScriptValueHandle) {
        self.handle = handle
    }

    deinit {
        idax_script_value_free(handle)
    }

    /// The raw handle, for the duration of `body`. Ownership does not transfer.
    func withHandle<CallResult>(_ body: (IdaxScriptValueHandle) -> CallResult) -> CallResult {
        body(handle)
    }

    /// Gives up the handle without running `deinit`; the caller must free it.
    consuming func takeHandle() -> IdaxScriptValueHandle {
        let taken = handle
        discard self
        return taken
    }

    private static func make(
        _ fallback: String,
        _ body: (UnsafeMutablePointer<IdaxScriptValueHandle?>) -> Int32
    ) throws(IDAError) -> ScriptValue {
        var out: IdaxScriptValueHandle? = nil
        try checkStatus(body(&out), fallback)
        guard let out else {
            throw IDAError(
                category: .internal,
                code: 0,
                message: "\(fallback) reported success but returned no value"
            )
        }
        return ScriptValue(owning: out)
    }

    // MARK: - Construction

    public init(integer: Int64) throws(IDAError) {
        self = try ScriptValue.make("script.value.integer") {
            idax_script_value_integer(integer, $0)
        }
    }

    public init(floatingPoint: Double) throws(IDAError) {
        self = try ScriptValue.make("script.value.floating") {
            idax_script_value_floating(floatingPoint, $0)
        }
    }

    /// Builds a string value from UTF-8 bytes. IDC strings may contain NUL, so
    /// the length is explicit rather than NUL-terminated.
    public init(string: String) throws(IDAError) {
        let bytes = Array(string.utf8)
        self = try ScriptValue.make("script.value.string") { out in
            bytes.withUnsafeBufferPointer { buffer in
                idax_script_value_string(buffer.baseAddress, buffer.count, out)
            }
        }
    }

    /// Builds an empty IDC object.
    public static func object() throws(IDAError) -> ScriptValue {
        try make("script.value.object") { idax_script_value_object($0) }
    }

    /// A shallow copy.
    public func clone() throws(IDAError) -> ScriptValue {
        try ScriptValue.make("script.value.clone") { idax_script_value_clone(handle, $0) }
    }

    /// A copy that also duplicates nested objects.
    public func deepCopy() throws(IDAError) -> ScriptValue {
        try ScriptValue.make("script.value.deepCopy") {
            idax_script_value_deep_copy(handle, $0)
        }
    }

    // MARK: - Reading

    public func kind() throws(IDAError) -> ScriptValueKind {
        let raw = try withOutput("script.value.kind", Int32(0)) {
            idax_script_value_kind(handle, $0)
        }
        guard let kind = ScriptValueKind(rawValue: raw) else {
            throw IDAError(
                category: .internal,
                code: raw,
                message: "Unknown script value kind \(raw)"
            )
        }
        return kind
    }

    /// Reads an integer, failing when the value is not one.
    public func asInteger() throws(IDAError) -> Int64 {
        try withOutput("script.value.asInteger", Int64(0)) {
            idax_script_value_as_integer(handle, $0)
        }
    }

    /// Reads a floating-point number, failing when the value is not one.
    public func asFloatingPoint() throws(IDAError) -> Double {
        try withOutput("script.value.asFloating", Double(0)) {
            idax_script_value_as_floating(handle, $0)
        }
    }

    /// Reads a string, failing when the value is not one.
    ///
    /// Bytes are decoded as UTF-8 with replacement, since IDC imposes no
    /// encoding of its own.
    public func asString() throws(IDAError) -> String {
        try readString("script.value.asString") {
            idax_script_value_as_string(handle, $0, $1)
        }
    }

    /// Converts to an integer, following IDC's own coercion rules.
    public func coerceToInteger() throws(IDAError) -> Int64 {
        try withOutput("script.value.coerceInteger", Int64(0)) {
            idax_script_value_coerce_integer(handle, $0)
        }
    }

    /// Converts to a floating-point number, following IDC's coercion rules.
    public func coerceToFloatingPoint() throws(IDAError) -> Double {
        try withOutput("script.value.coerceFloating", Double(0)) {
            idax_script_value_coerce_floating(handle, $0)
        }
    }

    /// Converts to a string, following IDC's coercion rules.
    public func coerceToString() throws(IDAError) -> String {
        try readString("script.value.coerceString") {
            idax_script_value_coerce_string(handle, $0, $1)
        }
    }

    /// Renders the value the way IDA prints it.
    public func render(name: String = "", indent: Int = 0) throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(
            idax_script_value_render(handle, name, indent, &out),
            "script.value.render"
        )
        return takeCString(out)
    }

    /// The class name of an object value.
    public func className() throws(IDAError) -> String {
        var out: UnsafeMutablePointer<CChar>? = nil
        try checkStatus(idax_script_value_class_name(handle, &out), "script.value.className")
        return takeCString(out)
    }

    // MARK: - Object attributes

    /// Reads an attribute.
    ///
    /// - Parameter useHandler: let the object's attribute handler run, rather
    ///   than reading storage directly.
    public func attribute(
        _ name: String,
        useHandler: Bool = true
    ) throws(IDAError) -> ScriptValue {
        try ScriptValue.make("script.value.attribute") {
            idax_script_value_attribute(handle, name, useHandler ? 1 : 0, $0)
        }
    }

    /// Writes an attribute. `value` is borrowed — C++ copies out of it.
    public func setAttribute(
        _ name: String,
        to value: borrowing ScriptValue,
        useHandler: Bool = true
    ) throws(IDAError) {
        try checkStatus(
            value.withHandle {
                idax_script_value_set_attribute(handle, name, $0, useHandler ? 1 : 0)
            },
            "script.value.setAttribute"
        )
    }

    /// Names of every attribute this object carries.
    public func attributeNames() throws(IDAError) -> [String] {
        var pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        var count: Int = 0
        try checkStatus(
            idax_script_value_attribute_names(handle, &pointer, &count),
            "script.value.attributeNames"
        )
        defer { idax_script_string_array_free(pointer, count) }
        guard let pointer, count > 0 else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).map { borrowCString($0) }
    }

    /// Removes an attribute.
    ///
    /// - Returns: whether there was one to remove.
    @discardableResult
    public func removeAttribute(_ name: String) throws(IDAError) -> Bool {
        try withOutput("script.value.removeAttribute", Int32(0)) {
            idax_script_value_remove_attribute(handle, name, $0)
        } != 0
    }

    // MARK: - Slices and references

    /// A half-open slice of a string or array value.
    public func slice(from begin: Int, to end: Int) throws(IDAError) -> ScriptValue {
        try ScriptValue.make("script.value.slice") {
            idax_script_value_slice(handle, begin, end, $0)
        }
    }

    /// Replaces a half-open slice. `replacement` is borrowed.
    public func replaceSlice(
        from begin: Int,
        to end: Int,
        with replacement: borrowing ScriptValue
    ) throws(IDAError) {
        try checkStatus(
            replacement.withHandle {
                idax_script_value_replace_slice(handle, begin, end, $0)
            },
            "script.value.replaceSlice"
        )
    }

    /// Follows a reference.
    public func dereference(
        mode: ScriptDereferenceMode = .once
    ) throws(IDAError) -> ScriptValue {
        try ScriptValue.make("script.value.dereference") {
            idax_script_value_dereference(handle, mode.rawValue, $0)
        }
    }

    // MARK: - Shared plumbing

    private func readString(
        _ fallback: String,
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
            UnsafeMutablePointer<Int>
        ) -> Int32
    ) throws(IDAError) -> String {
        var pointer: UnsafeMutablePointer<UInt8>? = nil
        var length: Int = 0
        try checkStatus(body(&pointer, &length), fallback)
        defer { idax_free_bytes(pointer) }
        guard let pointer, length > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: pointer, count: length), as: UTF8.self)
    }
}

/// An argument list for ``Script/call(_:arguments:resolvedNames:)``.
///
/// Exists because a `~Copyable` value cannot go into an `Array`. Appending
/// *consumes* the value: the list takes ownership and frees everything on
/// `deinit`, so the caller does not have to keep the individual values alive
/// across the call.
public struct ScriptArguments: ~Copyable {
    private var handles: [IdaxScriptValueHandle] = []

    public init() {}

    /// Takes ownership of `value` and appends it.
    public mutating func append(_ value: consuming ScriptValue) {
        // Ownership moves into this list, which frees it on deinit.
        handles.append(value.takeHandle())
    }

    public var count: Int { handles.count }

    deinit {
        for handle in handles {
            idax_script_value_free(handle)
        }
    }

    func withHandles<CallResult>(
        _ body: (UnsafePointer<IdaxScriptValueHandle?>?, Int) -> CallResult
    ) -> CallResult {
        let optionalHandles: [IdaxScriptValueHandle?] = handles
        return optionalHandles.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
    }
}

/// One name pre-resolved for the compiler, so a script can refer to it without
/// the resolver running.
public struct ScriptResolvedName: Sendable {
    public var name: String
    public var value: UInt64

    public init(name: String, value: UInt64) {
        self.name = name
        self.value = value
    }
}

/// Options for compiling script text or a snippet.
public struct ScriptCompileOptions: Sendable {
    /// Restrict the script to functions IDA considers safe.
    public var onlySafeFunctions: Bool
    public var resolvedNames: [ScriptResolvedName]

    public init(onlySafeFunctions: Bool = false, resolvedNames: [ScriptResolvedName] = []) {
        self.onlySafeFunctions = onlySafeFunctions
        self.resolvedNames = resolvedNames
    }
}

/// Options for compiling a script file.
public struct ScriptFileCompileOptions: Sendable {
    public var deleteMacrosAfterCompilation: Bool
    public var allowProgramLabels: Bool
    public var onlySafeFunctions: Bool

    public init(
        deleteMacrosAfterCompilation: Bool = false,
        allowProgramLabels: Bool = false,
        onlySafeFunctions: Bool = false
    ) {
        self.deleteMacrosAfterCompilation = deleteMacrosAfterCompilation
        self.allowProgramLabels = allowProgramLabels
        self.onlySafeFunctions = onlySafeFunctions
    }

    func withRaw<CallResult>(
        _ body: (UnsafePointer<IdaxScriptFileCompileOptions>) -> CallResult
    ) -> CallResult {
        var raw = IdaxScriptFileCompileOptions()
        raw.delete_macros_after_compilation = deleteMacrosAfterCompilation ? 1 : 0
        raw.allow_program_labels = allowProgramLabels ? 1 : 0
        raw.only_safe_functions = onlySafeFunctions ? 1 : 0
        return withUnsafePointer(to: &raw) { body($0) }
    }
}

/// Whether a compilation succeeded, and why not when it did not.
///
/// A failed compilation is not a thrown error — the diagnostics are the result.
public struct ScriptCompilationResult: Sendable {
    public let succeeded: Bool
    public let error: String
}

/// Whether an execution succeeded, its value, and why not when it did not.
///
/// Move-only because it owns the returned value.
public struct ScriptExecutionResult: ~Copyable {
    public let succeeded: Bool
    public let error: String
    private var valueHandle: IdaxScriptValueHandle?

    init(raw: IdaxScriptExecutionResult) {
        self.succeeded = raw.succeeded != 0
        self.error = borrowCString(raw.error)
        self.valueHandle = raw.value
    }

    /// Takes the returned value, leaving the result without one.
    ///
    /// Mutating rather than consuming, so ``succeeded`` and ``error`` remain
    /// readable afterwards. A second call returns `nil`.
    public mutating func takeValue() -> ScriptValue? {
        guard let handle = valueHandle else { return nil }
        // Clearing the handle is what stops `deinit` from double-freeing it.
        valueHandle = nil
        return ScriptValue.adopting(handle)
    }

    deinit {
        if let valueHandle {
            idax_script_value_free(valueHandle)
        }
    }
}

/// Whether an integer-returning execution succeeded.
public struct ScriptIntegerExecutionResult: Sendable {
    public let succeeded: Bool
    public let value: Int64
    public let error: String
}

extension ScriptValue {
    /// Wraps a handle whose ownership has already transferred to us.
    static func adopting(_ handle: IdaxScriptValueHandle) -> ScriptValue {
        ScriptValue(owning: handle)
    }
}

/// IDC scripting: evaluation, compilation, execution, and globals.
public enum Script {

    // MARK: - Evaluation

    /// Evaluates an expression in the currently selected scripting language.
    public static func evaluate(
        _ expression: String,
        at address: Address = badAddress
    ) throws(IDAError) -> ScriptExecutionResult {
        try execution("script.evaluate") { idax_script_evaluate(expression, address, $0) }
    }

    /// Evaluates an expression as IDC specifically.
    public static func evaluateIDC(
        _ expression: String,
        at address: Address = badAddress
    ) throws(IDAError) -> ScriptExecutionResult {
        try execution("script.evaluateIDC") { idax_script_evaluate_idc(expression, address, $0) }
    }

    /// Evaluates an expression expected to produce an integer.
    public static func evaluateInteger(
        _ expression: String,
        at address: Address = badAddress
    ) throws(IDAError) -> ScriptIntegerExecutionResult {
        var raw = IdaxScriptIntegerExecutionResult()
        try checkStatus(
            idax_script_evaluate_integer(expression, address, &raw),
            "script.evaluateInteger"
        )
        defer { idax_script_integer_execution_result_free(&raw) }
        return ScriptIntegerExecutionResult(
            succeeded: raw.succeeded != 0,
            value: raw.value,
            error: borrowCString(raw.error)
        )
    }

    /// Evaluates a snippet with names pre-resolved.
    public static func evaluateSnippet(
        _ source: String,
        resolvedNames: [ScriptResolvedName] = []
    ) throws(IDAError) -> ScriptExecutionResult {
        try execution("script.evaluateSnippet") { out in
            withResolvedNames(resolvedNames) { names, count in
                idax_script_evaluate_snippet(source, names, count, out)
            }
        }
    }

    // MARK: - Compilation

    /// Compiles a script file.
    public static func compileFile(
        _ path: String,
        options: ScriptFileCompileOptions = ScriptFileCompileOptions()
    ) throws(IDAError) -> ScriptCompilationResult {
        try compilation("script.compileFile") { out in
            options.withRaw { idax_script_compile_file(path, $0, out) }
        }
    }

    /// Compiles script source text.
    public static func compileText(
        _ source: String,
        options: ScriptCompileOptions = ScriptCompileOptions()
    ) throws(IDAError) -> ScriptCompilationResult {
        try compilation("script.compileText") { out in
            withCompileOptions(options) { idax_script_compile_text(source, $0, out) }
        }
    }

    /// Compiles a function body into a named function.
    public static func compileSnippet(
        functionName: String,
        body: String,
        options: ScriptCompileOptions = ScriptCompileOptions()
    ) throws(IDAError) -> ScriptCompilationResult {
        try compilation("script.compileSnippet") { out in
            withCompileOptions(options) {
                idax_script_compile_snippet(functionName, body, $0, out)
            }
        }
    }

    // MARK: - Invocation

    /// Calls a compiled function.
    public static func call(
        _ functionName: String,
        arguments: borrowing ScriptArguments,
        resolvedNames: [ScriptResolvedName] = []
    ) throws(IDAError) -> ScriptExecutionResult {
        try execution("script.call") { out in
            arguments.withHandles { handlePointer, handleCount in
                withResolvedNames(resolvedNames) { names, nameCount in
                    idax_script_call(
                        functionName, handlePointer, handleCount, names, nameCount, out
                    )
                }
            }
        }
    }

    /// Compiles a file and calls one of its functions.
    public static func executeScript(
        path: String,
        functionName: String,
        arguments: borrowing ScriptArguments,
        options: ScriptFileCompileOptions = ScriptFileCompileOptions()
    ) throws(IDAError) -> ScriptExecutionResult {
        try execution("script.executeScript") { out in
            arguments.withHandles { handlePointer, handleCount in
                options.withRaw {
                    idax_script_execute_script(
                        path, functionName, handlePointer, handleCount, $0, out
                    )
                }
            }
        }
    }

    /// Runs one of IDA's own bundled scripts.
    public static func executeSystemScript(
        _ file: String,
        complainIfMissing: Bool = true
    ) throws(IDAError) {
        try checkStatus(
            idax_script_execute_system_script(file, complainIfMissing ? 1 : 0),
            "script.executeSystemScript"
        )
    }

    // MARK: - Environment

    /// Replaces the include search paths.
    public static func setIncludePaths(_ paths: [String]) throws(IDAError) {
        try checkStatus(
            withStringArray(paths) { idax_script_set_include_paths($0, $1) },
            "script.setIncludePaths"
        )
    }

    /// Adds to the include search paths.
    public static func appendIncludePaths(_ paths: [String]) throws(IDAError) {
        try checkStatus(
            withStringArray(paths) { idax_script_append_include_paths($0, $1) },
            "script.appendIncludePaths"
        )
    }

    /// Resolves a file against the include paths.
    ///
    /// - Returns: `nil` when it is not found, which is not an error.
    public static func resolveFile(_ file: String) throws(IDAError) -> String? {
        var out: UnsafeMutablePointer<CChar>? = nil
        var hasValue: Int32 = 0
        try checkStatus(
            idax_script_resolve_file(file, &out, &hasValue),
            "script.resolveFile"
        )
        guard hasValue != 0 else {
            if out != nil { _ = takeCString(out) }
            return nil
        }
        return takeCString(out)
    }

    /// Names of compiled functions starting with `prefix`.
    public static func functionNames(
        prefix: String = "",
        maximum: Int = 1000
    ) throws(IDAError) -> [String] {
        var pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
        var count: Int = 0
        try checkStatus(
            idax_script_function_names(prefix, maximum, &pointer, &count),
            "script.functionNames"
        )
        defer { idax_script_string_array_free(pointer, count) }
        guard let pointer, count > 0 else { return [] }
        return UnsafeBufferPointer(start: pointer, count: count).map { borrowCString($0) }
    }

    // MARK: - Globals

    /// Reads a global, or `nil` when it does not exist.
    public static func global(_ name: String) throws(IDAError) -> ScriptValue? {
        var out: IdaxScriptValueHandle? = nil
        var hasValue: Int32 = 0
        try checkStatus(idax_script_global(name, &out, &hasValue), "script.global")
        guard hasValue != 0, let out else { return nil }
        return ScriptValue.adopting(out)
    }

    /// Writes a global. `value` is borrowed.
    ///
    /// - Returns: whether the global was created rather than overwritten.
    @discardableResult
    public static func setGlobal(
        _ name: String,
        to value: borrowing ScriptValue
    ) throws(IDAError) -> Bool {
        var created: Int32 = 0
        try checkStatus(
            value.withHandle { idax_script_set_global(name, $0, &created) },
            "script.setGlobal"
        )
        return created != 0
    }

    /// Obtains a reference to an *existing* global.
    ///
    /// Fails with `NotFound` when the global does not exist — it does not
    /// create one. Use ``setGlobal(_:to:)`` first.
    public static func referenceGlobal(_ name: String) throws(IDAError) -> ScriptValue {
        var out: IdaxScriptValueHandle? = nil
        try checkStatus(idax_script_reference_global(name, &out), "script.referenceGlobal")
        guard let out else {
            throw IDAError(
                category: .internal,
                code: 0,
                message: "script.referenceGlobal reported success but returned no value"
            )
        }
        return ScriptValue.adopting(out)
    }

    // MARK: - Shared plumbing

    private static func execution(
        _ fallback: String,
        _ body: (UnsafeMutablePointer<IdaxScriptExecutionResult>) -> Int32
    ) throws(IDAError) -> ScriptExecutionResult {
        var raw = IdaxScriptExecutionResult()
        try checkStatus(body(&raw), fallback)
        // The result adopts the value handle; only the error string is freed here.
        let result = ScriptExecutionResult(raw: raw)
        raw.value = nil
        idax_script_execution_result_free(&raw)
        return result
    }

    private static func compilation(
        _ fallback: String,
        _ body: (UnsafeMutablePointer<IdaxScriptCompilationResult>) -> Int32
    ) throws(IDAError) -> ScriptCompilationResult {
        var raw = IdaxScriptCompilationResult()
        try checkStatus(body(&raw), fallback)
        defer { idax_script_compilation_result_free(&raw) }
        return ScriptCompilationResult(
            succeeded: raw.succeeded != 0,
            error: borrowCString(raw.error)
        )
    }
}

// MARK: - C array plumbing

private func withStringArray<CallResult>(
    _ values: [String],
    _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> CallResult
) -> CallResult {
    let cStrings = values.map { strdup($0) }
    defer { cStrings.forEach { free($0) } }
    return cStrings.withUnsafeBufferPointer { buffer in
        buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
            body(rebound.baseAddress, rebound.count)
        }
    }
}

private func withResolvedNames<CallResult>(
    _ names: [ScriptResolvedName],
    _ body: (UnsafePointer<IdaxScriptResolvedName>?, Int) -> CallResult
) -> CallResult {
    guard !names.isEmpty else { return body(nil, 0) }
    let cStrings = names.map { strdup($0.name) }
    defer { cStrings.forEach { free($0) } }

    var raw = [IdaxScriptResolvedName]()
    raw.reserveCapacity(names.count)
    for (index, entry) in names.enumerated() {
        var item = IdaxScriptResolvedName()
        item.name = UnsafePointer(cStrings[index])
        item.value = entry.value
        raw.append(item)
    }
    return raw.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
}

private func withCompileOptions<CallResult>(
    _ options: ScriptCompileOptions,
    _ body: (UnsafePointer<IdaxScriptCompileOptions>) -> CallResult
) -> CallResult {
    withResolvedNames(options.resolvedNames) { names, count in
        var raw = IdaxScriptCompileOptions()
        raw.only_safe_functions = options.onlySafeFunctions ? 1 : 0
        raw.resolved_names = names
        raw.resolved_name_count = count
        return withUnsafePointer(to: &raw) { body($0) }
    }
}
