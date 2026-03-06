import CIDA
import Darwin

/// Function chunk descriptor.
public struct Chunk: Sendable {
    public let start: Address
    public let end: Address
    public let isTail: Bool
    public let owner: Address
}

/// Stack frame information.
public struct StackFrame: Sendable {
    public let localVariablesSize: AddressSize
    public let savedRegistersSize: AddressSize
    public let argumentsSize: AddressSize
    public let totalSize: AddressSize
    public let variables: [FrameVariable]
}

/// Stack frame variable.
public struct FrameVariable: Sendable {
    public let name: String
    public let byteOffset: Int
    public let byteSize: Int
    public let comment: String
    public let isSpecial: Bool
}

/// Opaque snapshot of a function.
public struct Function: Sendable {
    public let start: Address
    public let end: Address
    public let name: String
    public let bitness: Int
    public let returns: Bool
    public let isLibrary: Bool
    public let isThunk: Bool
    public let isVisible: Bool
    public let frameLocalSize: AddressSize
    public let frameRegsSize: AddressSize
    public let frameArgsSize: AddressSize

    public var size: AddressSize { end &- start }

    // MARK: - Queries

    public static func at(_ address: Address) throws(IDAError) -> Function {
        var raw = IdaxFunction()
        try checkStatus(idax_function_at(address, &raw), "function.at")
        defer { idax_function_free(&raw) }
        return Function(raw: raw)
    }

    public static func byIndex(_ index: Int) throws(IDAError) -> Function {
        var raw = IdaxFunction()
        try checkStatus(idax_function_by_index(index, &raw), "function.byIndex")
        defer { idax_function_free(&raw) }
        return Function(raw: raw)
    }

    public static func count() throws(IDAError) -> Int {
        var out: Int = 0
        try checkStatus(idax_function_count(&out), "function.count")
        return out
    }

    public static func all() throws(IDAError) -> [Function] {
        let n = try count()
        var result: [Function] = []
        result.reserveCapacity(n)
        for i in 0..<n { result.append(try byIndex(i)) }
        return result
    }

    public static func callers(of address: Address) throws(IDAError) -> [Address] {
        try withAddressArrayOutput("function.callers") { idax_function_callers(address, $0, $1) }
    }

    public static func callees(of address: Address) throws(IDAError) -> [Address] {
        try withAddressArrayOutput("function.callees") { idax_function_callees(address, $0, $1) }
    }

    // MARK: - Mutation

    public static func create(start: Address, end: Address) throws(IDAError) -> Function {
        var raw = IdaxFunction()
        try checkStatus(idax_function_create(start, end, &raw), "function.create")
        defer { idax_function_free(&raw) }
        return Function(raw: raw)
    }

    public static func remove(at address: Address) throws(IDAError) {
        try checkStatus(idax_function_remove(address), "function.remove")
    }

    // MARK: - Frame

    public static func frame(at address: Address) throws(IDAError) -> StackFrame {
        var raw = IdaxStackFrame()
        try checkStatus(idax_function_frame(address, &raw), "function.frame")
        defer { idax_stack_frame_free(&raw) }

        var vars: [FrameVariable] = []
        if let ptr = raw.variables, raw.variable_count > 0 {
            let buf = UnsafeBufferPointer(start: ptr, count: raw.variable_count)
            vars = buf.map { v in
                FrameVariable(
                    name: borrowCString(v.name),
                    byteOffset: v.byte_offset,
                    byteSize: v.byte_size,
                    comment: borrowCString(v.comment),
                    isSpecial: v.is_special != 0
                )
            }
        }

        return StackFrame(
            localVariablesSize: raw.local_variables_size,
            savedRegistersSize: raw.saved_registers_size,
            argumentsSize: raw.arguments_size,
            totalSize: raw.total_size,
            variables: vars
        )
    }

    // MARK: - Chunks

    public static func chunks(of address: Address) throws(IDAError) -> [Chunk] {
        var ptr: UnsafeMutablePointer<IdaxChunk>? = nil
        var count: Int = 0
        try checkStatus(idax_function_chunks(address, &ptr, &count), "function.chunks")
        defer { free(ptr) }
        guard let ptr, count > 0 else { return [] }
        let buf = UnsafeBufferPointer(start: ptr, count: count)
        return buf.map { c in
            Chunk(start: c.start, end: c.end, isTail: c.is_tail != 0, owner: c.owner)
        }
    }

    // MARK: - Internal

    init(raw: IdaxFunction) {
        self.start = raw.start
        self.end = raw.end
        self.name = borrowCString(raw.name)
        self.bitness = Int(raw.bitness)
        self.returns = raw.returns != 0
        self.isLibrary = raw.is_library != 0
        self.isThunk = raw.is_thunk != 0
        self.isVisible = raw.is_visible != 0
        self.frameLocalSize = raw.frame_local_size
        self.frameRegsSize = raw.frame_regs_size
        self.frameArgsSize = raw.frame_args_size
    }
}
