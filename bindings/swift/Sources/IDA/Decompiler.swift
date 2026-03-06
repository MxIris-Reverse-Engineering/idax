import CIDA

/// Local variable from decompilation.
public struct LocalVariable: Sendable {
    public let name: String
    public let typeName: String
    public let isArgument: Bool
    public let width: Int
    public let hasUserName: Bool
    public let storage: Int
    public let comment: String
}

/// Decompiled function handle.
///
/// Reference type — `deinit` frees the underlying handle.
public final class DecompiledFunction: @unchecked Sendable {
    let handle: IdaxDecompiledHandle

    init(_ handle: IdaxDecompiledHandle) {
        self.handle = handle
    }

    deinit {
        idax_decompiled_free(handle)
    }

    public var pseudocode: String {
        get throws(IDAError) {
            try withStringOutput("decompiled.pseudocode") { idax_decompiled_pseudocode(handle, $0) }
        }
    }

    public var declaration: String {
        get throws(IDAError) {
            try withStringOutput("decompiled.declaration") { idax_decompiled_declaration(handle, $0) }
        }
    }

    public var entryAddress: Address {
        get throws(IDAError) {
            try withOutput("decompiled.entryAddress", UInt64(0)) { idax_decompiled_entry_address(handle, $0) }
        }
    }

    public var lines: [String] {
        get throws(IDAError) {
            var ptr: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? = nil
            var count: Int = 0
            try checkStatus(idax_decompiled_lines(handle, &ptr, &count), "decompiled.lines")
            defer { idax_decompiled_lines_free(ptr, count) }
            guard let ptr, count > 0 else { return [] }
            return (0..<count).map { i in
                if let s = ptr[i] { String(cString: s) } else { "" }
            }
        }
    }

    public var variables: [LocalVariable] {
        get throws(IDAError) {
            var ptr: UnsafeMutablePointer<IdaxLocalVariable>? = nil
            var count: Int = 0
            try checkStatus(idax_decompiled_variables(handle, &ptr, &count), "decompiled.variables")
            defer { idax_decompiled_variables_free(ptr, count) }
            guard let ptr, count > 0 else { return [] }
            let buf = UnsafeBufferPointer(start: ptr, count: count)
            return buf.map { v in
                LocalVariable(
                    name: borrowCString(v.name),
                    typeName: borrowCString(v.type_name),
                    isArgument: v.is_argument != 0,
                    width: Int(v.width),
                    hasUserName: v.has_user_name != 0,
                    storage: Int(v.storage),
                    comment: borrowCString(v.comment)
                )
            }
        }
    }

    public func renameVariable(from oldName: String, to newName: String) throws(IDAError) {
        try checkStatus(
            oldName.withCString { o in
                newName.withCString { n in
                    idax_decompiled_rename_variable(handle, o, n)
                }
            },
            "decompiled.renameVariable"
        )
    }
}

/// Decompiler facade.
///
/// Mirrors C++ `ida::decompiler`.
public enum Decompiler {
    public static func isAvailable() throws(IDAError) -> Bool {
        var out: Int32 = 0
        try checkStatus(idax_decompiler_available(&out), "decompiler.available")
        return out != 0
    }

    public static func decompile(at address: Address) throws(IDAError) -> DecompiledFunction {
        var handle: IdaxDecompiledHandle?
        try checkStatus(idax_decompiler_decompile(address, &handle), "decompiler.decompile")
        guard let handle else {
            throw IDAError(category: .internal, code: 0, message: "nil handle after successful call")
        }
        return DecompiledFunction(handle)
    }
}
